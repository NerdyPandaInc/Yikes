// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

contract JINDO is
    Initializable,
    ERC20PermitUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    uint256 public constant INITIAL_SUPPLY = 180_000_000_000_000 * 1e18;
    uint16  public constant MAX_REFLECTION_BP = 200;
    uint16  public constant MAX_TAX_BP = 560;
    uint256 public constant TRUE_BURN_CAP = INITIAL_SUPPLY / 10;

    uint256 private _tTotal;
    uint256 private _rTotal;
    uint256 private _tFeeTotal;
    uint256 public totalTrueBurned;

    mapping(address => uint256) private _rOwned;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool) private _isExcludedFromFee;
    mapping(address => bool) private _isBlacklisted;
    mapping(address => uint256) private _lastTrade;

    address public devWallet;
    address public treasuryWallet;
    address public burnWallet;

    uint256 public cooldown;
    bool public tradingEnabled;
    uint16 public reflectionBP;
    uint16 public taxBP;

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

    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _rOwned[account] / _getRate();
    }

    function allowance(address owner_, address spender) public view override returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address recipient, uint256 amount)
        public override whenNotPaused returns (bool)
    {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount)
        public override whenNotPaused returns (bool)
    {
        _transfer(sender, recipient, amount);
        _approve(sender, msg.sender, _allowances[sender][msg.sender] - amount);
        return true;
    }

    function _approve(address owner_, address spender, uint256 amount) internal {
        require(owner_ != address(0) && spender != address(0), "zero address");
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    function _transfer(address from, address to, uint256 tAmount) internal {
        require(from != address(0) && to != address(0), "zero address");
        require(!_isBlacklisted[from] && !_isBlacklisted[to], "blacklisted");
        require(balanceOf(from) >= tAmount, "insufficient balance");
        require(tradingEnabled || _isExcludedFromFee[from], "trading not live");
        require(block.timestamp >= _lastTrade[from] + cooldown, "cooldown active");

        _lastTrade[from] = block.timestamp;

        uint256 rate = _getRate();
        uint256 rAmount = tAmount * rate;
        uint256 rTransfer;
        uint256 tTransfer;

        bool takeFee = !(_isExcludedFromFee[from] || _isExcludedFromFee[to]);

        if (takeFee) {
            // 1) Reflection
            uint256 tRef = (tAmount * reflectionBP) / 10_000;
            uint256 rRef = tRef * rate;
            _rTotal -= rRef;
            _tFeeTotal += tRef;

            // 2) Total tax
            uint256 tTax = (tAmount * taxBP) / 10_000;
            uint256 rTax = tTax * rate;

            // 3) Net transfer
            tTransfer = tAmount - tRef - tTax;
            rTransfer = rAmount - rRef - rTax;

            // 4) Split tax
            uint256 tShare = tTax / 3;
            uint256 rShare = tShare * rate;
            uint256 tDust = tTax - (tShare * 3);

            _rOwned[devWallet] += rShare + (tDust * rate);
            _rOwned[treasuryWallet] += rShare;

            // 5) True-burn with cap
            uint256 capRemaining = TRUE_BURN_CAP > totalTrueBurned
                ? TRUE_BURN_CAP - totalTrueBurned
                : 0;
            uint256 tBurnActual = tShare <= capRemaining ? tShare : capRemaining;

            if (tBurnActual > 0) {
                uint256 rBurn = tBurnActual * rate;
                totalTrueBurned += tBurnActual;
                _tTotal -= tBurnActual;
                _rTotal -= rBurn;
                emit Transfer(from, address(0), tBurnActual);
            }

            // 6) Sink remainder (post-cap burn)
            uint256 tSink = tShare - tBurnActual;
            if (tSink > 0) {
                _rOwned[burnWallet] += tSink * rate;
                emit Transfer(from, burnWallet, tSink);
            }

            emit TaxDistributed(from, tRef, tTax, tShare + tDust, tShare, tBurnActual);
        } else {
            tTransfer = tAmount;
            rTransfer = rAmount;
        }

        _rOwned[from] -= rAmount;
        _rOwned[to] += rTransfer;
        emit Transfer(from, to, tTransfer);

        // Invariant check
        assert(_rTotal % _tTotal == 0);
    }

    function _getRate() private view returns (uint256) {
        return _rTotal / _tTotal;
    }

    // Enable trading once ready (irreversible toggle)
    function enableTrading() external onlyOwner {
        tradingEnabled = true;
        emit TradingEnabled();
    }

    // Pause/unpause in emergencies
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // Adjust cooldown duration (in seconds)
    function setCooldown(uint256 newCooldown) external onlyOwner {
        emit CooldownUpdated(cooldown, newCooldown);
        cooldown = newCooldown;
    }

    // Change fees (basis points)
    function setFees(uint16 _refBP, uint16 _taxBP) external onlyOwner {
        require(_refBP <= MAX_REFLECTION_BP, "exceeds reflection cap");
        require(_taxBP <= MAX_TAX_BP, "exceeds tax cap");
        reflectionBP = _refBP;
        taxBP = _taxBP;
        emit FeesUpdated(_refBP, _taxBP);
    }

    // Manage wallet exclusions from fees/cooldown
    function setFeeExemption(address account, bool exempt) external onlyOwner {
        _isExcludedFromFee[account] = exempt;
        emit FeeExemption(account, exempt);
    }

    // Blacklist or unblacklist any address
    function blacklist(address user, bool flag) external onlyOwner {
        _isBlacklisted
