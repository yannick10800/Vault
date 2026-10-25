// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/* ============================== interfaces ============================== */

interface IERC4626Full {
    function asset() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function convertToShares(uint256) external view returns (uint256);
    function convertToAssets(uint256) external view returns (uint256);
    function previewDeposit(uint256) external view returns (uint256);
    function previewWithdraw(uint256) external view returns (uint256);
    function maxDeposit(address) external view returns (uint256);
    function maxWithdraw(address) external view returns (uint256);
    function maxRedeem(address) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @dev LlamaLend v2 LendController. `_d_*` params are DELTAS.
interface ILendController {
    function create_loan(uint256 _collateral, uint256 _debt, uint256 _N, address _for) external;
    function borrow_more(uint256 _collateral, uint256 _debt, address _for) external;
    function add_collateral(uint256 _collateral, address _for) external;
    function remove_collateral(uint256 _collateral, address _for) external;
    function repay(uint256 _wallet_d_debt, address _for) external;

    function max_borrowable(uint256 _d_collateral, uint256 _N, address _user) external view returns (uint256);
    function debt(address _user) external view returns (uint256);
    function loan_exists(address _user) external view returns (bool);
    function user_state(address _user) external view returns (uint256[4] memory); // [collateral, borrowed, debt, N]
    function available_balance() external view returns (uint256);
    function borrow_cap() external view returns (uint256);
    function total_debt() external view returns (uint256);
    function loan_discount() external view returns (uint256);
    function extra_health(address _user) external view returns (uint256);
    function amm() external view returns (address);
    function remove_collateral_health_preview(uint256 _collateral, address _for, bool _full)
        external view returns (int256);
}

interface IAMM {
    function price_oracle() external view returns (uint256); // crvUSD per 1 collateral, 1e18
}

/// @dev Subset of VaultV3.vy used for read-only debt lookup.
interface IVaultV3 {
    function asset() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function convertToAssets(uint256) external view returns (uint256);
}

/* ================================ strategy ============================== */

/// @title  Levered svZCHF -> crvUSD -> yvcrvUSD-2 loop, as a Yearn V3 strategy
/// @notice ZCHF in  -> svZCHF -> LlamaLend collateral -> borrow crvUSD @ target LTV -> Yearn vault
///         ZCHF out <- unwrap svZCHF <- free collateral <- repay debt <- redeem Yearn vault
/// @dev    ERC4626 over ZCHF. `VaultV3.vy` is the sole depositor and share holder.
///         Implements the VaultV3 `IStrategy` surface: asset(), maxDeposit(), report(),
///         deposit(assets,receiver), redeem(shares,receiver,owner).
contract LeveredSvZchfStrategy is ERC4626, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /* ------------------------------ immutables ----------------------------- */

    IERC20  internal constant ZCHF   = IERC20(0xb58e61c3098d85632df34eecfb899a1ed80921cb);
    IERC20  internal constant CRVUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);

    IERC4626Full internal constant SVZCHF       = IERC4626Full(0xE5F130253fF137f9917C0107659A4c5262abf6b0);
    IERC4626Full internal constant YEARN_CRVUSD = IERC4626Full(0xBF319dDC2Edc1Eb6FDf9910E39b37Be221C8805F);
    ILendController internal constant CONTROLLER =
        ILendController(0xFd85e847cDd2549f213E276e4B57B0690169F043);

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    /* -------------------------------- storage ------------------------------ */

    address public vault;               // the owning VaultV3
    address public keeper;
    address public emergencyAdmin;
    bool    public shutdown;            // stop new investment (mirrors TokenizedStrategy)

    uint256 public targetLtvBps = 7_500;  // 75%
    uint256 public bands        = 10;     // LlamaLend `_N`, 4..50
    uint256 public lastTotalAssets;       // report fallback if vault debt is unreadable

    event VaultSet(address vault);
    event ParamsSet(uint256 targetLtvBps, uint256 bands);
    event Invested(uint256 assets, uint256 collateralShares, uint256 borrowed);
    event Divested(uint256 assets, uint256 collateralShares, uint256 repaid);
    event ShutdownSet(bool shutdown);
    event Swept(address token, uint256 amount);

    modifier onlyVault() { require(msg.sender == vault, "!vault"); _; }
    modifier onlyVaultOrKeeper() { require(msg.sender == vault || msg.sender == keeper, "!auth"); _; }

    constructor()
        ERC4626(ZCHF)
        ERC20("Levered svZCHF Loop Strategy", "stZCHF")
        Ownable(msg.sender)
    {
        keeper = msg.sender;
        emergencyAdmin = msg.sender;
    }

    /* ================================ admin ================================ */

    function setVault(address _vault) external onlyOwner {
        require(vault == address(0), "set");
        require(IERC4626Full(_vault).asset() == address(ZCHF), "asset");
        vault = _vault;
        emit VaultSet(_vault);
    }

    function setKeeper(address _k) external onlyOwner { keeper = _k; }
    function setEmergencyAdmin(address _a) external onlyOwner { emergencyAdmin = _a; }

    function setParams(uint256 _targetLtvBps, uint256 _bands) external onlyOwner {
        require(_targetLtvBps >= 1_000 && _targetLtvBps <= 9_000, "ltv");
        require(_bands >= 4 && _bands <= 50, "bands");
        targetLtvBps = _targetLtvBps;
        bands = _bands;
        emit ParamsSet(_targetLtvBps, _bands);
    }

    function setShutdown(bool _s) external {
        require(msg.sender == owner() || msg.sender == emergencyAdmin, "!auth");
        shutdown = _s;
        emit ShutdownSet(_s);
    }

    function sweep(address _token) external onlyOwner {
        require(_token != address(ZCHF), "asset");
        uint256 b = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(owner(), b);
        emit Swept(_token, b);
    }

    /* ============================ IStrategy surface ======================== */

    /// @notice VaultV3 IStrategy: no-arg deposit limit.
    function maxDeposit() external view returns (uint256) { return _maxDepositAssets(); }

    /// @notice VaultV3 IStrategy: profit/loss vs the vault's recorded strategy debt.
    /// @dev MUST NOT revert — the vault's process_report reverts if it does.
    function report() external onlyVaultOrKeeper returns (uint256 profit, uint256 loss) {
        uint256 assets = totalAssets();
        uint256 debt = _vaultDebt();
        if (assets >= debt) profit = assets - debt;
        else loss = debt - assets;
        lastTotalAssets = assets;
    }

    function isShutdown() external view returns (bool) { return shutdown; }
    function apiVersion() external pure returns (string memory) { return "3.0.2"; }

    /// @notice Keeper hook: re-sync leverage to target (borrow interest drifts LTV up).
    function rebalance() external onlyVaultOrKeeper {
        uint256 n = bands;
        uint256 debt = CONTROLLER.debt(address(this));
        if (debt == 0) { _investIdle(); return; }

        uint256 maxMore = CONTROLLER.max_borrowable(0, n, address(this));
        uint256 targetTotal = _targetDebt(maxMore, debt);

        if (targetTotal > debt) {
            uint256 more = _capByLiquidity(targetTotal - debt);
            if (more > 0) CONTROLLER.borrow_more(0, more, address(this));
        } else if (debt > targetTotal) {
            uint256 redeemed = _redeemCrvUsdFromYearn(debt - targetTotal);
            if (redeemed > 0) {
                _approve(CRVUSD, address(CONTROLLER), redeemed);
                CONTROLLER.repay(redeemed, address(this));
            }
        }
        _depositCrvUsdToYearn();
    }

    /// @notice Full unwind, callable by emergency admin even while shutdown.
    function emergencyWithdraw() external {
        require(msg.sender == owner() || msg.sender == emergencyAdmin, "!auth");
        uint256 coll = CONTROLLER.user_state(address(this))[0];
        if (coll > 0) _divest(type(uint256).max);
        _depositCrvUsdToYearn();
    }

    /* ============================ ERC4626 hooks =========================== */

    function totalAssets() public view override returns (uint256) {
        uint256 idle = asset().balanceOf(address(this));
        uint256 collZchf = SVZCHF.convertToAssets(CONTROLLER.user_state(address(this))[0]);

        uint256 debt = CONTROLLER.debt(address(this));
        uint256 yearnCrvUsd = YEARN_CRVUSD.convertToAssets(YEARN_CRVUSD.balanceOf(address(this)));

        // NOTE: vault shares minted to us are intentionally NOT counted here.
        // VaultV3 mints profit shares to itself and unlocks them over profitMaxUnlockTime;
        // the vault already books that profit in strategy.total_debt.
        if (yearnCrvUsd >= debt) {
            return idle + collZchf + _crvUsdToZchf(yearnCrvUsd - debt);
        }
        uint256 deficit = _crvUsdToZchf(debt - yearnCrvUsd);
        uint256 base = idle + collZchf;
        return base > deficit ? base - deficit : 0;
    }

    /// @dev Honest max: what we can actually free right now.
    function maxDeposit(address) public view override returns (uint256) {
        return _maxDepositAssets();
    }

    function maxMint(address) public view override returns (uint256) {
        return previewDeposit(_maxDepositAssets());
    }

    function maxWithdraw(address _owner) public view override returns (uint256) {
        uint256 freeable = _maxFreeable();
        uint256 owned = convertToAssets(balanceOf(_owner));
        return freeable < owned ? freeable : owned;
    }

    function maxRedeem(address _owner) public view override returns (uint256) {
        return _convertToShares(maxWithdraw(_owner), Math.Rounding.Floor);
    }

    function _deposit(address _caller, address _receiver, uint256 _assets, uint256 _shares)
        internal override
    {
        super._deposit(_caller, _receiver, _assets, _shares); // pulls ZCHF in, mints shares
        if (!shutdown) _invest(_assets);
    }

    function _withdraw(address _caller, address _receiver, address _owner, uint256 _assets, uint256 _shares)
        internal override
    {
        _divest(_assets);                                     // free ZCHF BEFORE the transfer
        super._withdraw(_caller, _receiver, _owner, _assets, _shares);
    }

    /* ============================== internals ============================= */

    function _maxDepositAssets() internal view returns (uint256) {
        if (shutdown) return 0;
        // svZCHF wrapper capacity is the binding constraint; borrow room of 0 is fine
        // (collateral still gets deposited, just unlevered).
        return SVZCHF.maxDeposit(address(this));
    }

    /// @dev Upper bound on ZCHF that can leave the loop without breaking health.
    function _maxFreeable() internal view returns (uint256) {
        uint256 idle = asset().balanceOf(address(this));
        uint256 collShares = CONTROLLER.user_state(address(this))[0];
        if (collShares == 0) return idle;

        uint256 collZchf = SVZCHF.convertToAssets(collShares);
        uint256 debt = CONTROLLER.debt(address(this));
        if (debt == 0) return idle + collZchf;

        // crvUSD we can ACTUALLY pull out of the Yearn vault right now
        uint256 liquid = YEARN_CRVUSD.maxWithdraw(address(this));
        if (liquid > debt) liquid = debt;

        // collateral safely removable while keeping health >= 0 at target LTV
        uint256 removableZchf = _crvUsdToZchf(liquid * BPS / targetLtvBps);
        if (removableZchf > collZchf) removableZchf = collZchf;
        return idle + removableZchf;
    }

    function _invest(uint256 _assets) internal {
        if (_assets == 0) return;

        // dust guard: OZ deposit silently donates assets that round to 0 shares
        if (SVZCHF.previewDeposit(_assets) == 0) return;

        _approve(ZCHF, address(SVZCHF), _assets);
        uint256 shares = SVZCHF.deposit(_assets, address(this));

        _addCollateralAndBorrow(shares);
        _depositCrvUsdToYearn();
    }

    function _investIdle() internal {
        uint256 idle = asset().balanceOf(address(this));
        if (idle > 0 && !shutdown) _invest(idle);
    }

    function _divest(uint256 _assets) internal {
        uint256 idle = asset().balanceOf(address(this));
        if (_assets <= idle) return;

        uint256 collShares = CONTROLLER.user_state(address(this))[0];
        if (collShares == 0) return;

        uint256 need = _assets - idle;

        uint256 sharesToRemove = SVZCHF.previewWithdraw(need); // rounds up
        if (sharesToRemove > collShares) sharesToRemove = collShares;

        uint256 repayTarget = _sharesToCrvUsd(sharesToRemove) * targetLtvBps / BPS;
        uint256 debt = CONTROLLER.debt(address(this));
        if (repayTarget > debt) repayTarget = debt;

        // 1. free crvUSD from the Yearn vault
        uint256 redeemed = _redeemCrvUsdFromYearn(repayTarget);

        // 2. repay BEFORE collateral leaves the market
        if (redeemed > 0) {
            _approve(CRVUSD, address(CONTROLLER), redeemed);
            CONTROLLER.repay(redeemed, address(this));
        }

        // 3. remove collateral (full size; LTV drifts up rather than under-delivering)
        sharesToRemove = _healthCapped(sharesToRemove);
        CONTROLLER.remove_collateral(sharesToRemove, address(this));
        SVZCHF.redeem(sharesToRemove, address(this), address(this));

        // 4. leftover crvUSD back to work
        _depositCrvUsdToYearn();

        emit Divested(_assets, sharesToRemove, redeemed);
    }

    function _healthCapped(uint256 _shares) internal view returns (uint256) {
        if (CONTROLLER.debt(address(this)) == 0) return _shares;
        uint256 s = _shares;
        for (uint256 i; i < 5 && s > 0; ++i) {
            if (CONTROLLER.remove_collateral_health_preview(s, address(this), false) >= 0) return s;
            s = s * 9 / 10;
        }
        return s;
    }

    function _addCollateralAndBorrow(uint256 _collateralShares) internal {
        if (_collateralShares == 0) return;
        uint256 n = bands;

        _approve(IERC20(address(SVZCHF)), address(CONTROLLER), _collateralShares);

        if (!CONTROLLER.loan_exists(address(this))) {
            uint256 maxDebt = CONTROLLER.max_borrowable(_collateralShares, n, address(this));
            uint256 debt = _capByLiquidity(_targetDebt(maxDebt, 0));
            CONTROLLER.create_loan(_collateralShares, debt, n, address(this));
            emit Invested(_collateralShares, _collateralShares, debt);
        } else {
            CONTROLLER.add_collateral(_collateralShares, address(this));
            uint256 debt = CONTROLLER.debt(address(this));
            uint256 maxMore = CONTROLLER.max_borrowable(0, n, address(this));
            uint256 targetTotal = _targetDebt(maxMore, debt);
            uint256 more;
            if (targetTotal > debt) {
                more = _capByLiquidity(targetTotal - debt);
                if (more > 0) CONTROLLER.borrow_more(0, more, address(this));
            }
            emit Invested(_collateralShares, _collateralShares, more);
        }
    }

    /// @dev max_borrowable reports room at MAX ltv; scale to our target.
    function _targetDebt(uint256 _maxBorrowable, uint256 _currentDebt) internal view returns (uint256) {
        uint256 discount = CONTROLLER.loan_discount() + CONTROLLER.extra_health(address(this));
        uint256 maxLtv = discount >= WAD ? WAD : WAD - discount;
        return (_maxBorrowable + _currentDebt) * (targetLtvBps * WAD / BPS) / maxLtv;
    }

    function _capByLiquidity(uint256 _debt) internal view returns (uint256) {
        uint256 cap = CONTROLLER.borrow_cap();
        uint256 used = CONTROLLER.total_debt();
        uint256 capLeft = cap > used ? cap - used : 0;
        uint256 avail = CONTROLLER.available_balance();
        uint256 lim = avail < capLeft ? avail : capLeft;
        return _debt < lim ? _debt : lim;
    }

    function _depositCrvUsdToYearn() internal {
        uint256 bal = CRVUSD.balanceOf(address(this));
        if (bal == 0) return;
        uint256 lim = YEARN_CRVUSD.maxDeposit(address(this));
        if (lim < bal) bal = lim;
        if (bal == 0) return;
        _approve(CRVUSD, address(YEARN_CRVUSD), bal);
        YEARN_CRVUSD.deposit(bal, address(this));
    }

    function _redeemCrvUsdFromYearn(uint256 _wanted) internal returns (uint256) {
        if (_wanted == 0) return 0;
        uint256 shares = YEARN_CRVUSD.previewWithdraw(_wanted);
        uint256 maxShares = YEARN_CRVUSD.maxRedeem(address(this));
        if (shares > maxShares) shares = maxShares;
        if (shares == 0) return 0;
        uint256 before = CRVUSD.balanceOf(address(this));
        YEARN_CRVUSD.redeem(shares, address(this), address(this));
        return CRVUSD.balanceOf(address(this)) - before;
    }

    function _sharesToCrvUsd(uint256 _shares) internal view returns (uint256) {
        return _shares * _oraclePrice() / WAD;
    }

    /// @dev crvUSD -> ZCHF via the market oracle + the svZCHF exchange rate.
    function _crvUsdToZchf(uint256 _crvUsd) internal view returns (uint256) {
        if (_crvUsd == 0) return 0;
        uint256 p = _oraclePrice();
        uint256 sharePrice = SVZCHF.convertToAssets(WAD);
        if (p == 0 || sharePrice == 0) return _crvUsd;
        return _crvUsd * sharePrice / p;
    }

    /// @dev Non-reverting oracle read so report()/totalAssets() cannot brick.
    function _oraclePrice() internal view returns (uint256 p) {
        try IAMM(CONTROLLER.amm()).price_oracle() returns (uint256 v) { p = v; } catch {}
        if (p == 0) p = SVZCHF.convertToAssets(WAD);
    }

    /// @dev VaultV3 StrategyParams { activation, last_report, current_debt, max_debt }.
    ///      Falls back to lastTotalAssets if the shape is unexpected.
    function _vaultDebt() internal view returns (uint256) {
        address v = vault;
        if (v == address(0)) return lastTotalAssets;
        (bool ok, bytes memory d) =
            v.staticcall(abi.encodeWithSignature("strategies(address)", address(this)));
        if (ok && d.length >= 128) {
            uint256 currentDebt;
            assembly { currentDebt := mload(add(d, 0x60)) } // 3rd word
            return currentDebt;
        }
        return lastTotalAssets;
    }

    function _approve(IERC20 _token, address _spender, uint256 _amount) internal {
        if (_token.allowance(address(this), _spender) < _amount) {
            _token.forceApprove(_spender, _amount);
        }
    }
}
