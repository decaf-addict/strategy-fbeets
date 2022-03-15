// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
import "../interfaces/BalancerV2.sol";
import "../interfaces/MasterChef.sol";
import "../interfaces/Beethoven.sol";
import "../interfaces/DelegateRegistry.sol";


contract Strategy is BaseStrategy {
    IDelegateRegistry public delegateRegistry;
    IBeethovenxMasterChef public masterChef;
    IBalancerVault public bVault;
    IBeetsBar public fBeets;
    Params public params;
    IBalancerPool public constant stakeLp = IBalancerPool(0xcdE5a11a4ACB4eE4c805352Cec57E236bdBC3837);

    uint public masterChefPoolId;
    IERC20 public constant beets = IERC20(0xF24Bcf4d1e507740041C9cFd2DddB29585aDCe1e);
    IERC20 public constant wftm = IERC20(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);

    IAsset[] internal assets;
    uint256 internal constant max = type(uint256).max;
    uint256 internal constant basisOne = 10000;

    struct Params {
        bool autocompound;
        bool abandonRewards;
    }

    constructor(address _vault, address _bVault, address _masterChef, uint _masterChefPoolId) public BaseStrategy(_vault) {
        bVault = IBalancerVault(_bVault);

        masterChef = IBeethovenxMasterChef(_masterChef);
        require(masterChef.lpTokens(_masterChefPoolId) == address(want), "wrong mc pool!");

        masterChefPoolId = _masterChefPoolId;
        fBeets = IBeetsBar(address(want));

        assets = [IAsset(address(wftm)), IAsset(address(beets))];
        beets.safeApprove(address(bVault), max);
        stakeLp.approve(address(fBeets), max);
        fBeets.approve(address(masterChef), max);

        params = Params({autocompound : true, abandonRewards : false});
        delegateRegistry = IDelegateRegistry(0x469788fE6E9E9681C6ebF3bF78e7Fd26Fc015446);
    }

    function name() external view override returns (string memory) {
        return "fbeets compounder";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(balanceOfWantInMasterChef());
    }

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment){
        if (params.autocompound) {
            _claimRewards();
            _joinPool(balanceOfReward());
            _mintFBeets(balanceOfStakeLp());
            _depositIntoMasterChef(balanceOfWant());
        }

        uint256 totalDebt = vault.strategies(address(this)).totalDebt;
        uint256 totalAssetsAfterProfit = estimatedTotalAssets();

        _profit = totalAssetsAfterProfit > totalDebt ? totalAssetsAfterProfit.sub(totalDebt) : 0;

        uint256 _amountFreed;
        uint256 _toLiquidate = _debtOutstanding.add(_profit);
        if (_toLiquidate > 0) {
            (_amountFreed, _loss) = liquidatePosition(_toLiquidate);
        }

        _debtPayment = Math.min(_debtOutstanding, _amountFreed);

        if (_loss > _profit) {
            // Example:
            // debtOutstanding 100, profit 50, _amountFreed 100, _loss 50
            // loss should be 0, (50-50)
            // profit should endup in 0
            _loss = _loss.sub(_profit);
            _profit = 0;
        } else {
            // Example:
            // debtOutstanding 100, profit 50, _amountFreed 140, _loss 10
            // _profit should be 40, (50 profit - 10 loss)
            // loss should end up in 0
            _profit = _profit.sub(_loss);
            _loss = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (_debtOutstanding > 0) {
            _depositIntoMasterChef(balanceOfWant());
        }
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss){
        uint256 loose = balanceOfWant();
        if (_amountNeeded > loose) {
            uint toExit = _amountNeeded.sub(loose);
            _withdrawFromMasterChef(address(this), toExit);

            _liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded);
            _loss = _amountNeeded.sub(_liquidatedAmount);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        _withdrawFromMasterChef(address(this), balanceOfWantInMasterChef());
        return balanceOfWant();
    }


    function prepareMigration(address _newStrategy) internal override {
        _withdrawFromMasterChef(_newStrategy, balanceOfWantInMasterChef());
        uint256 _balanceOfStakeLp = balanceOfStakeLp();
        if (_balanceOfStakeLp > 0) {
            stakeLp.transfer(_newStrategy, _balanceOfStakeLp);
        }
        uint256 rewards = balanceOfReward();
        if (rewards > 0) {
            beets.safeTransfer(_newStrategy, rewards);
        }
    }

    function protectedTokens() internal view override returns (address[] memory){}

    function ethToWant(uint256 _amtInWei) public view virtual override returns (uint256){
        return 0;
    }


    // HELPERS //
    function balanceOfWant() public view returns (uint256 _amount){
        return want.balanceOf(address(this));
    }

    function balanceOfReward() public view returns (uint256 _amount){
        return beets.balanceOf(address(this));
    }

    function balanceOfStakeLp() public view returns (uint256 _amount){
        return stakeLp.balanceOf(address(this));
    }

    function balanceOfWantInMasterChef() public view returns (uint256 _amount){
        (_amount,) = masterChef.userInfo(masterChefPoolId, address(this));
    }

    function getPendingBeets() public view returns (uint256){
        return masterChef.pendingBeets(masterChefPoolId, address(this));
    }

    function withdrawFromMasterChef(uint256 _amount) external onlyVaultManagers {
        _withdrawFromMasterChef(address(this), _amount);
    }

    // AbandonRewards withdraws lp without rewards. Specify where to withdraw to
    function _withdrawFromMasterChef(address _to, uint256 _amount) internal {
        _amount = Math.min(balanceOfWantInMasterChef(), _amount);
        if (_amount > 0) {
            params.abandonRewards
            ? masterChef.emergencyWithdraw(masterChefPoolId, address(_to))
            : masterChef.withdrawAndHarvest(masterChefPoolId, _amount, address(_to));
        }
    }

    function claimRewards() external onlyVaultManagers {
        _claimRewards();
    }

    // claim all beets rewards from masterchef
    function _claimRewards() internal {
        if (getPendingBeets() > 0) {
            masterChef.harvest(masterChefPoolId, address(this));
        }
    }

    function joinPool(uint _beets) external onlyVaultManagers {
        _joinPool(_beets);
    }

    function _joinPool(uint _beets) internal {
        if (_beets > 0) {
            uint256[] memory maxAmountsIn = new uint256[](2);
            // wftm 0
            // beets 1
            maxAmountsIn[1] = _beets;
            bytes memory userData = abi.encode(IBalancerVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, maxAmountsIn, 0);
            IBalancerVault.JoinPoolRequest memory request = IBalancerVault.JoinPoolRequest(assets, maxAmountsIn, userData, false);
            bVault.joinPool(stakeLp.getPoolId(), address(this), address(this), request);
        }
    }

    function mintFBeets(uint _bpts) external onlyVaultManagers {
        _mintFBeets(_bpts);
    }

    function _mintFBeets(uint _bpts) internal {
        if (_bpts > 0) {
            fBeets.enter(_bpts);
        }
    }

    function depositIntoMasterChef(uint _fBeets) external onlyVaultManagers {
        _depositIntoMasterChef(_fBeets);
    }

    function _depositIntoMasterChef(uint _fBeets) internal {
        if (_fBeets > 0) {
            masterChef.deposit(masterChefPoolId, _fBeets, address(this));
        }
    }

    function setDelegate(bytes32 _id, address _delegate) public onlyVaultManagers {
        delegateRegistry.setDelegate(_id, _delegate);
    }

    function clearDelegate(bytes32 _id) public onlyVaultManagers {
        delegateRegistry.clearDelegate(_id);
    }

    // SETTERS //

    function setParams(bool _autocompound, bool _abandon) external onlyVaultManagers {
        params.autocompound = _autocompound;
        params.abandonRewards = _abandon;
    }

    function setDelegateRegistry(address _registry) external onlyGovernance {
        delegateRegistry = IDelegateRegistry(_registry);
    }
}
