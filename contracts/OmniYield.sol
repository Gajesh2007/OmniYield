// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "./lzApp/NonblockingLzApp.sol";
import "../node_modules/@aave/core-v3/contracts/interfaces/IPool.sol";
import "../node_modules/@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IStargateRouter.sol";

interface Vault {
    function deposit(uint256 _amount) external returns (uint256); 
    function withdraw(uint256 _maxShares) external returns (uint256);
}

contract OmniYield is NonblockingLzApp {
    uint16 public srcChainId;
    uint16 public dstChainId;
    uint16 public currentChainId;
    
    IERC20 public src_coin;
    IERC20 public dst_coin;

    uint256 public srcPoolId;
    uint256 public dstPoolId;

    IStargateRouter public stargateRouter;
    Vault public yearnVault;

    uint256 MAX = 115792089237316195423570985008687907853269984665640564039457584007913129639935;

    constructor(
        address _lzEndpoint, 
        uint16 _srcChainId, 
        uint16 _dstChainId,
        uint16 _currentChainId,
        IERC20 _src_coin, 
        IERC20 _dst_coin
    ) NonblockingLzApp(_lzEndpoint) {
        srcChainId = _srcChainId;
        dstChainId = _dstChainId;
        currentChainId = _currentChainId;
        src_coin = _src_coin;
        dst_coin = _dst_coin;
    }

    struct UserData {
        uint256 balance;
    }

    mapping (address => UserData) public user;

    function _nonblockingLzReceive(uint16 _srcChainId, bytes memory _srcAddress, uint64 _nonce, bytes memory _payload) internal override {
        require(_srcChainId == dstChainId, "Invalid Chain");
        address srcAddress;
        assembly {
            srcAddress := mload(add(_srcAddress, 20))
        }

        require(srcAddress == address(this));

        /// @param amount amount of vault shares
        (address userAddress, uint256 amount) = abi.decode(_payload, (address, uint256));

        require(amount <= user[userAddress].balance, "You don't have enough shares");
        
        bytes memory data = abi.encode(userAddress);

        uint256 balance_before = dst_coin.balanceOf(address(this));
        yearnVault.withdraw(amount);
        uint256 amount_received = dst_coin.balanceOf(address(this)) - balance_before;

        dst_coin.approve(address(stargateRouter), MAX);

        // Stargate's Router.swap() function sends the tokens to the destination chain.
        stargateRouter.swap{value:msg.value}(
            dstChainId,                                     // the destination chain id
            srcPoolId,                                      // the source Stargate poolId
            dstPoolId,                                      // the destination Stargate poolId
            payable(msg.sender),                            // refund adddress. if msg.sender pays too much gas, return extra eth
            amount_received,                                // total tokens to send to destination chain
            0,                                              // min amount allowed out
            IStargateRouter.lzTxObj(200000, 0, "0x"),       // default lzTxObj
            abi.encodePacked(address(this)),                // destination address
            data                                            // bytes payload
        );
    }


    function estimateFee(uint16 _dstChainId, bool _useZro, bytes memory PAYLOAD, bytes calldata _adapterParams) public view returns (uint nativeFee, uint zroFee) {
        return lzEndpoint.estimateFees(_dstChainId, address(this), PAYLOAD, _useZro, _adapterParams);
    }

    function deposit(uint256 _amount) public payable {
        require(srcChainId == currentChainId, "Wrong Chain");
        src_coin.transferFrom(msg.sender, address(this), _amount);

        require(_amount > 0, "amount must be greater than 0");
        require(msg.value > 0, "stargate requires fee to pay crosschain message");

        bytes memory data = abi.encode(msg.sender);

        // this contract calls stargate swap()
        src_coin.transferFrom(msg.sender, address(this), _amount);
        src_coin.approve(address(stargateRouter), _amount);

        // Stargate's Router.swap() function sends the tokens to the destination chain.
        stargateRouter.swap{value:msg.value}(
            dstChainId,                                     // the destination chain id
            srcPoolId,                                      // the source Stargate poolId
            dstPoolId,                                      // the destination Stargate poolId
            payable(msg.sender),                            // refund adddress. if msg.sender pays too much gas, return extra eth
            _amount,                                        // total tokens to send to destination chain
            0,                                              // min amount allowed out
            IStargateRouter.lzTxObj(200000, 0, "0x"),       // default lzTxObj
            abi.encodePacked(address(this)),                // destination address 
            data                                            // bytes payload
        );
    }

    function withdraw(uint256 _amount) public payable {
        require(dstChainId == currentChainId, "Wrong Chain");
        require(_amount > 0, "amount must be greater than 0");
        require(msg.value > 0, "stargate requires fee to pay crosschain message");

        bytes memory data = abi.encode(msg.sender, _amount); // TODO: placeholder

        _lzSend(
            dstChainId, 
            data, 
            payable(msg.sender), 
            address(0x0), 
            bytes(""),
            msg.value
        );
    }

    /// @param _chainId The remote chainId sending the tokens
    /// @param _srcAddress The remote Bridge address
    /// @param _nonce The message ordering nonce
    /// @param _token The token contract on the local chain
    /// @param amountLD The qty of local _token contract tokens  
    /// @param _payload The bytes containing the toAddress
    function sgReceive(
        uint16 _chainId, 
        bytes memory _srcAddress, 
        uint _nonce, 
        address _token, 
        uint amountLD, 
        bytes memory _payload
    ) external {
        require(
            msg.sender == address(stargateRouter), 
            "only stargate router can call sgReceive!"
        );
        address srcAddress;
        assembly {
            srcAddress := mload(add(_srcAddress, 20))
        }

        require(srcAddress == address(this));
        require(srcChainId == _chainId || dstChainId == _chainId, "Invalid Chain");

        (address _add) = abi.decode(_payload, (address));
        
        if (srcChainId == _chainId) {
            dst_coin.approve(address(yearnVault), MAX);
            uint256 vault_shares = yearnVault.deposit(amountLD);
            require(address(dst_coin) == _token, "Invalid Token");

            user[_add].balance += vault_shares;
        } else if (dstChainId == _chainId) {
            require(address(src_coin) == _token, "Invalid Token");

            src_coin.transfer(_add, amountLD);
        }
    }
}
