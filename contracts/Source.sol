// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "./lzApp/NonblockingLzApp.sol";
import "../node_modules/@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IStargateRouter.sol";

contract Source is NonblockingLzApp {
    uint16 dstChainId;
    uint256 srcPoolId;
    uint256 dstPoolId;
    // Destination Contract Address
    address srcAddress;
    IERC20 token;

    IStargateRouter public stargateRouter;

    uint256 MAX = 115792089237316195423570985008687907853269984665640564039457584007913129639935;

    constructor(
        address _lzEndpoint, 
        uint16 _chainId,
        uint256 _srcPoolId,
        uint256 _dstPoolId,
        address _srcAddress,
        IERC20 _token,
        IStargateRouter _stargateRouter
    ) NonblockingLzApp(_lzEndpoint) {
        dstChainId = _chainId;
        srcPoolId = _srcPoolId;
        dstPoolId = _dstPoolId;
        srcAddress = _srcAddress;
        token = _token;
        stargateRouter = _stargateRouter;
    }

    function deposit(uint256 _amount) public payable {
        token.transferFrom(msg.sender, address(this), _amount);

        require(_amount > 0, "amount must be greater than 0");
        require(msg.value > 0, "stargate requires fee to pay crosschain message");

        bytes memory data = abi.encode(msg.sender);

        // this contract calls stargate swap()
        // token.transferFrom(msg.sender, address(this), MAX);
        token.approve(address(stargateRouter), MAX);

        // Stargate's Router.swap() function sends the tokens to the destination chain.
        stargateRouter.swap{value:msg.value}(
            dstChainId,                                     // the destination chain id
            srcPoolId,                                      // the source Stargate poolId
            dstPoolId,                                      // the destination Stargate poolId
            payable(msg.sender),                            // refund adddress. if msg.sender pays too much gas, return extra eth
            _amount,                                        // total tokens to send to destination chain
            0,                                              // min amount allowed out
            IStargateRouter.lzTxObj(200000, 0, "0x"),       // default lzTxObj
            abi.encodePacked(srcAddress),                // destination address 
            data                                            // bytes payload
        );
    }

    function withdraw(uint256 _amount) public payable {
        require(_amount > 0, "amount must be greater than 0");
        require(msg.value > 0, "stargate requires fee to pay crosschain message");

        bytes memory data = abi.encode(msg.sender, _amount);

        _lzSend(
            dstChainId, 
            data, 
            payable(msg.sender), 
            address(0x0), 
            bytes(""),
            msg.value
        );
    }


    function _nonblockingLzReceive(uint16 _srcChainId, bytes memory _srcAddress, uint64 _nonce, bytes memory _payload) internal override {
        
    }

    function estimateFee(uint16 _dstChainId, bool _useZro, bytes memory PAYLOAD, bytes calldata _adapterParams) public view returns (uint nativeFee, uint zroFee) {
        return lzEndpoint.estimateFees(_dstChainId, address(this), PAYLOAD, _useZro, _adapterParams);
    }
}
