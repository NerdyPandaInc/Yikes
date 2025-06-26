// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

/// @title  JINDO Token
/// @notice ERC-20 + Reflection + 10% true-burn cap + 5.6% tax (3-way split)
///         + EIP-2612 Permit + UUPS + Pausable + Cooldown + Blacklist
contract JINDO is
    Initializable,
    ERC20PermitUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    // ─────────── EVENTS ───────────────────────────────────────────
    event FeesUpdated(uint16 reflectionBP, uint16 taxBP);
    event TradingEnabled();
    event CooldownUpdated(uint256 oldCd, uint256 newCd);
    event Blacklisted(address indexed user, bool flag);
    event FeeExemption(address indexed acct, bool excluded);
    event TaxDistributed(
        address indexed from,
        uint256 tReflection,
        uint256 tTax,
        uint256 toDev,
        uint256 toTreasury,
        uint256 toBurn
    );
    event DevWalletUpdated(address oldW, address newW);
    event TreasuryWalletUpdated(address oldW, address newW);
    event BurnWalletUpdated(address oldW, address newW);
    event RecoveredERC20(address token, address to, uint256 amount);
    event RecoveredETH(address to, uint256 amount);

    // ────────── CONSTANTS & CAPS ──────────────────────────────────
    uint256 public constant INITIAL_SUPPLY    = 180_000_000_000_000 * 1e18;
    uint16  public constant MAX_REFLECTION_BP = 200;   // ≤2.00%
    uint16  public constant MAX_TAX_BP        = 560;   // ≤5.60%
    uint256 public constant TRUE_BURN_CAP     = INITIAL_SUPPLY / 10; // 10%

    // ─────────── STORAGE ─────────────────────────────────────────
    uint256 private _tTotal;           // dynamic totalSupply
    uint256 private _rTotal;           // reflection “scaled” supply
    uint256 private _tFeeTotal;        // cumulative reflection fees
    uint256 public  totalTrueBurned;   // tokens actually burned

    mapping(address => uint256)                   private _rOwned;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool)                      private _isExcludedFromFee;
    mapping(address => bool)                      private _isBlacklisted;
    mapping(address => uint256)                   private _lastTrade;

    address public devWallet;
    address public treasuryWallet;
    address public burnWallet;

    uint256 public cooldown;       // seconds between trades
    bool    public tradingEnabled; // launch toggle

    uint16 public reflectionBP;    // in basis points
    uint16 public taxBP;           // in basis points

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    /// @notice Initialize once via proxy
    function initialize(
        address _dev,
        address _treasury,
        address _burn
    ) external initializer {
        __ERC20_init("JINDO Token", "JINDO");
        __ERC20Permit_init("JINDO Token");
        __Ownable_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        require(_dev      != address(0), "zero dev");
        require(_treasury != address(0), "zero treasury");
        require(_burn     != address(0), "zero burn");

        devWallet      = _dev;
        treasuryWallet = _treasury;
        burnWallet     = _burn;

        _tTotal = INITIAL_SUPPLY;
        _rTotal = type(uint256).max - (type(uint256).max % INITIAL_SUPPLY);

        // mint to deployer
        _rOwned[msg.sender] = _rTotal;

        // defaults
        cooldown       = 20 seconds;
        tradingEnabled = false;
        reflectionBP   = 140; // 1.4%
        taxBP          = 560; // 5.6%

        // exclude deployer/dev/treasury from fees + cooldown
        _isExcludedFromFee[msg.sender]   = true;
        _isExcludedFromFee[devWallet]    = true;
        _isExcludedFromFee[treasuryWallet] = true;

        emit FeesUpdated(reflectionBP, taxBP);
        emit Transfer(address(0), msg.sender, INITIAL_SUPPLY);
    }

    // ───────── ERC20 + RFI VIEWS ──────────────────────────────────

    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }
    function balanceOf(address acct) public view override returns (uint256) {
        return _rOwned[acct] / _getRate();
    }
    function allowance(address o, address s) public view override returns (uint256) {
        return _allowances[o][s];
    }

    /// @return current reflection rate (_rTotal / _tTotal)
    function getCurrentRate() external view returns (uint256) {
        return _getRate();
    }
    /// @return total tokens distributed as reflections
    function getTotalFeesDistributed() external view returns (uint256) {
        return _tFeeTotal;
    }
    /// @return total tokens removed via true-burn
    function getTotalTrueBurned() external view returns (uint256) {
        return totalTrueBurned;
    }

    // ───────── ERC20 STATE CHANGES ──────────────────────────────

    function approve(address spender, uint256 amt) public override returns (bool) {
        _approve(msg.sender, spender, amt);
        return true;
    }
    function transfer(address to, uint256 amt)
        public override whenNotPaused returns (bool)
    {
        _transfer(msg.sender, to, amt);
        return true;
    }
    function transferFrom(address from, address to, uint256 amt)
        public override whenNotPaused returns (bool)
    {
        _transfer(from, to, amt);
        _approve(from, msg.sender, _allowances[from][msg.sender] - amt);
        return true;
    }

    // ─────────── INTERNAL HELPERS ─────────────────────────────────

    function _approve(address owner_, address spender, uint256 amt) internal {
        require(owner_ != address(0) && spender != address(0), "zero addr");
        _allowances[owner_][spender] = amt;
        emit Approval(owner_, spender, amt);
    }

    /**
     * @dev Core transfer logic:
     *   - reflection fee
     *   - 3-way tax split
     *   - true-burn up to cap, then sink
     *   - cooldown + blacklist + trading toggle
     */
    function _transfer(address from, address to, uint256 tAmount) internal {
        require(from != address(0) && to != address(0), "zero addr");
        require(!_isBlacklisted[from] && !_isBlacklisted[to], "blacklisted");
        require(balanceOf(from) >= tAmount, "insufficient");
        require(tradingEnabled || _isExcludedFromFee[from], "trading disabled");
        require(block.timestamp >= _lastTrade[from] + cooldown, "cooldown");

        _lastTrade[from] = block.timestamp;

        uint256 rate    = _getRate();
        uint256 rAmount = tAmount * rate;
        uint256 rTransfer;
        uint256 tTransfer;

        bool takeFee = !(_isExcludedFromFee[from] || _isExcludedFromFee[to]);
        if (takeFee) {
            // 1) Reflection
            uint256 tRef = (tAmount * reflectionBP) / 10000;
            uint256 rRef = tRef * rate;
            _rTotal      -= rRef;
            _tFeeTotal   += tRef;

            // 2) Total tax
            uint256 tTax = (tAmount * taxBP) / 10000;
            uint256 rTax = tTax * rate;

            // 3) Net transfer
            tTransfer = tAmount - tRef - tTax;
            rTransfer = rAmount - rRef - rTax;

            // 4) Split tax into 3 equal shares + dust → dev
            uint256 tShare = tTax / 3;
            uint256 rShare = tShare * rate;
            uint256 tDust  = tTax - (tShare * 3);
            _rOwned[devWallet]      += rShare + tDust * rate;
            _rOwned[treasuryWallet] += rShare;

            // 5) True-burn up to cap
            uint256 remainCap = TRUE_BURN_CAP > totalTrueBurned
                                ? TRUE_BURN_CAP - totalTrueBurned
                                : 0;
            uint256 tBurnOrig  = tShare;
            uint256 tBurnActual = tBurnOrig <= remainCap ? tBurnOrig : remainCap;
            if (tBurnActual > 0) {
                uint256 rBurn = tBurnActual * rate;
                totalTrueBurned += tBurnActual;
                _tTotal         -= tBurnActual;
                _rTotal         -= rBurn;
                emit Transfer(from, address(0), tBurnActual);
            }

            // 6) Sink any post-cap burn-share
            uint256 tSink = tShare - tBurnActual;
            if (tSink > 0) {
                _rOwned[burnWallet] += tSink * rate;
                emit Transfer(from, burnWallet, tSink);
            }

            emit TaxDistributed(from, tRef, tTax,
                                tShare + tDust,
                                tShare,
                                tShare - tSink);
        } else {
            tTransfer = tAmount;
            rTransfer = rAmount;
        }

        // 7) Final balance updates
        _rOwned[from] -= rAmount;
        _rOwned[to]   += rTransfer;
        emit Transfer(from, to, tTransfer);

        // 8) Invariant check: rate must remain integral
        assert(_rTotal % _tTotal == 0);
    }

    function _getRate() private view returns (uint256) {
        return _rTotal / _tTotal;
    }

    // ───────── OWNER-ONLY CONTROLS ───────────────────────────────

    function enableTrading() external onlyOwner {
        tradingEnabled = true;
        emit TradingEnabled();
    }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setFeeExemption(address acct, bool ex) external onlyOwner {
        _isExcludedFromFee[acct] = ex;
        emit FeeExemption(acct, ex);
    }
    function blacklist(address user, bool flag) external onlyOwner {
        _isBlacklisted[user] = flag;
        emit Blacklisted(user, flag);
    }
    function setCooldown(uint256 newCd) external onlyOwner {
        emit CooldownUpdated(cooldown, newCd);
        cooldown = newCd;
    }
    function setFees(uint16 _refBP, uint16 _taxBP) external onlyOwner {
        require(_refBP <= MAX_REFLECTION_BP, "ref cap");
        require(_taxBP <= MAX_TAX_BP,         "tax cap");
        reflectionBP = _refBP;
        taxBP        = _taxBP;
        emit FeesUpdated(_refBP, _taxBP);
    }
    function setDevWallet(address w) external onlyOwner {
        require(w != address(0), "zero addr");
        emit DevWalletUpdated(devWallet, w);
        devWallet = w;
    }
    function setTreasuryWallet(address w) external onlyOwner {
        require(w != address(0), "zero addr");
        emit TreasuryWalletUpdated(treasuryWallet, w);
        treasuryWallet = w;
    }
    function setBurnWallet(address w) external onlyOwner {
        require(w != address(0), "zero addr");
        emit BurnWalletUpdated(burnWallet, w);
        burnWallet = w;
    }
    function recoverERC20(address token_, address to, uint256 amt)
        external onlyOwner
    {
        IERC20Upgradeable(token_).transfer(to, amt);
        emit RecoveredERC20(token_, to, amt);
    }
    function recoverETH(address to, uint256 amt) external onlyOwner {
        payable(to).transfer(amt);
        emit RecoveredETH(to, amt);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    receive() external payable {}
}