// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "./lzApp/NonblockingLzApp.sol";
import "../node_modules/@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IStargateRouter.sol";

interface Vault {
    function deposit(uint256 _amount) external returns (uint256); 
    function withdraw(uint256 _maxShares) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function pricePerShare() external view returns (uint256);
}

contract Destination is NonblockingLzApp {
    IERC20 public token;
    
    // Pool Id of the Destination chain
    uint256 public srcPoolId;

    IStargateRouter public stargateRouter = IStargateRouter(0x7612aE2a34E5A363E137De748801FB4c86499152);
    Vault public yearnVault;

    uint256 MAX = 115792089237316195423570985008687907853269984665640564039457584007913129639935;

    constructor(
        address _lzEndpoint, 
        uint16 _srcChainId,
        uint256 _srcPoolId, 
        uint256 _poolId,
        address _srcAddress,
        IERC20 _src_coin, 
        IERC20 _dst_coin,
        Vault _yearnVault
    ) NonblockingLzApp(_lzEndpoint) {
        srcPoolId = _srcPoolId;
        src[_srcChainId].allowed = true;
        src[_srcChainId].poolId = _poolId;
        src[_srcChainId].srcAddress = _srcAddress;
        src[_srcChainId].token = _src_coin;
        token = _dst_coin;
        yearnVault = _yearnVault;
    }

    struct UserData {
        uint256 balance;
    }

    struct SrcDetails {
        bool allowed;
        uint256 poolId;
        address srcAddress;
        IERC20 token;
    }

    mapping (address => UserData) public user;
    mapping (uint16 => SrcDetails) public src;

    function _nonblockingLzReceive(
        uint16 _srcChainId, 
        bytes memory _srcAddress, 
        uint64 _nonce, 
        bytes memory _payload
    ) internal override {
        require(src[_srcChainId].allowed, "Invalid Chain");
        address srcAddress;
        assembly {
            srcAddress := mload(add(_srcAddress, 20))
        }

        require(srcAddress == src[_srcChainId].srcAddress);

        /// @param amount amount of vault shares
        (address userAddress, uint256 amount) = abi.decode(_payload, (address, uint256));

        require(amount <= user[userAddress].balance, "You don't have enough shares");
        
        bytes memory data = abi.encode("0x");

        uint256 balance_before = token.balanceOf(address(this));
        yearnVault.withdraw(amount);
        uint256 amount_received = token.balanceOf(address(this)) - balance_before;

        token.approve(address(stargateRouter), MAX);

        uint256 pool_id = src[_srcChainId].poolId;

        // Stargate's Router.swap() function sends the tokens to the destination chain.
        stargateRouter.swap{value: 0.03 ether}(
            _srcChainId,                                     // the destination chain id
            srcPoolId,                                      // the source Stargate poolId
            pool_id,                                      // the destination Stargate poolId
            payable(msg.sender),                            // refund adddress. if msg.sender pays too much gas, return extra eth
            amount_received,                                // total tokens to send to destination chain
            0,                                              // min amount allowed out
            IStargateRouter.lzTxObj(200000, 0, "0x"),       // default lzTxObj
            abi.encodePacked(userAddress),                // destination address
            data                                            // bytes payload
        );
    }

    function updateSrcDetails(
        uint16 _chainId, 
        bool _allowed, 
        uint256 _poolId, 
        address _srcAddress, 
        IERC20 _token
    ) onlyOwner external {
        src[_chainId].allowed = _allowed;
        src[_chainId].poolId = _poolId;
        src[_chainId].srcAddress = _srcAddress;
        src[_chainId].token = _token;
    }

    function sgReceive(
        uint16 _chainId, 
        bytes memory _srcAddress, 
        uint _nonce, 
        address _token, 
        uint amountLD, 
        bytes memory _payload
    ) external {
        require(src[_chainId].allowed == true, "Invalid Chain");
        require(address(token) == _token, "Invalid Token");

        (address _add) = abi.decode(_payload, (address));
        
        token.approve(address(yearnVault), MAX);
        uint256 vault_shares = yearnVault.deposit(amountLD);

        user[_add].balance += vault_shares;
    }

    // Getter Functions


    function estimateFee(uint16 _dstChainId, bool _useZro, bytes memory PAYLOAD, bytes calldata _adapterParams) public view returns (uint nativeFee, uint zroFee) {
        return lzEndpoint.estimateFees(_dstChainId, address(this), PAYLOAD, _useZro, _adapterParams);
    }

    function getUserBalance(address _user) public view returns (uint256) {
        return user[_user].balance;
    }

    function getUnderlyingShares() public view returns (uint256) {
        return yearnVault.balanceOf(address(this));
    } 

    receive() external payable {}
}
