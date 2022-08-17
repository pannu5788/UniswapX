// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {IReactorCallback} from "../interfaces/IReactorCallback.sol";
import {Output} from "../interfaces/ReactorStructs.sol";
import {IUniV3SwapRouter} from "../external/IUniV3SwapRouter.sol";

contract UniswapV3Executor is IReactorCallback {

    address public immutable swapRouter;

    constructor(address _swapRouter) {
        swapRouter = _swapRouter;
    }

    function reactorCallback(
        Output[] calldata outputs,
        bytes calldata fillData
    ) external {
        address inputToken;
        uint24 fee;
        uint256 inputAmount;

        (inputToken, fee, inputAmount) = abi.decode(
            fillData, (address, uint24, uint256)
        );

        IUniV3SwapRouter(swapRouter).exactOutputSingle(IUniV3SwapRouter.ExactOutputSingleParams(
            inputToken,
            outputs[0].token,
            fee,
            address(this),
            outputs[0].amount,
            inputAmount,
            0
        ));
    }
}