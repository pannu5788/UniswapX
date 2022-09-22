// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.16;

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {IPermitPost, Permit, TokenDetails} from "permitpost/interfaces/IPermitPost.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {OrderValidator} from "../base/OrderValidator.sol";
import {ReactorEvents} from "../base/ReactorEvents.sol";
import {PermitPostLib} from "../lib/PermitPostLib.sol";
import {IReactorCallback} from "../interfaces/IReactorCallback.sol";
import {IReactor} from "../interfaces/IReactor.sol";
import {
    SignedOrder,
    ResolvedOrder,
    OrderInfo,
    OrderStatus,
    InputToken,
    Signature,
    OutputToken
} from "../base/ReactorStructs.sol";

/// @notice Generic reactor logic for settling off-chain signed orders
///     using arbitrary fill methods specified by a taker
abstract contract BaseReactor is IReactor, OrderValidator, ReactorEvents {
    using SafeTransferLib for ERC20;
    using PermitPostLib for address;

    IPermitPost public immutable permitPost;

    constructor(address _permitPost) {
        permitPost = IPermitPost(_permitPost);
    }

    /// @inheritdoc IReactor
    function execute(SignedOrder memory order, address fillContract, bytes calldata fillData) external override {
        SignedOrder[] memory orders = new SignedOrder[](1);
        orders[0] = order;

        executeBatch(orders, fillContract, fillData);
    }

    /// @inheritdoc IReactor
    function executeBatch(SignedOrder[] memory orders, address fillContract, bytes calldata fillData) public override {
        ResolvedOrder[] memory resolvedOrders = new ResolvedOrder[](orders.length);
        bytes32[] memory orderHashes = new bytes32[](orders.length);
        Signature[] memory signatures = new Signature[](orders.length);
        unchecked {
            for (uint256 i = 0; i < orders.length; i++) {
                resolvedOrders[i] = resolve(orders[i].order);
                orderHashes[i] = keccak256(orders[i].order);
                signatures[i] = orders[i].sig;
            }
        }
        _fill(resolvedOrders, signatures, orderHashes, fillContract, fillData);
    }

    /// @notice validates and fills a list of orders, marking it as filled
    function _fill(
        ResolvedOrder[] memory orders,
        Signature[] memory signatures,
        bytes32[] memory orderHashes,
        address fillContract,
        bytes calldata fillData
    ) internal {
        unchecked {
            for (uint256 i = 0; i < orders.length; i++) {
                _validateOrderInfo(orders[i].info);
                _updateFilled(orderHashes[i]);
                _transferTokens(orders[i], signatures[i], orderHashes[i], fillContract);
            }
        }

        IReactorCallback(fillContract).reactorCallback(orders, fillData);

        unchecked {
            // transfer output tokens to their respective recipients
            for (uint256 i = 0; i < orders.length; i++) {
                for (uint256 j = 0; j < orders[i].outputs.length; j++) {
                    OutputToken memory output = orders[i].outputs[j];
                    ERC20(output.token).safeTransferFrom(fillContract, output.recipient, output.amount);
                }

                emit Fill(orderHashes[i], msg.sender, orders[i].info.nonce, orders[i].info.offerer);
            }
        }
    }

    /// @notice Transfers tokens to the fillContract using permitPost
    function _transferTokens(ResolvedOrder memory order, Signature memory sig, bytes32 orderHash, address fillContract)
        private
    {
        Permit memory permit = Permit({
            tokens: order.input.token.toTokenDetails(order.input.amount),
            spender: address(this),
            deadline: order.info.deadline,
            // Note: PermitPost verifies for us that the user signed over the orderHash
            // using the witness parameter of the permit
            witness: orderHash
        });
        address[] memory to = new address[](1);
        to[0] = fillContract;

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = order.input.amount;

        address sender = permitPost.unorderedTransferFrom(permit, to, ids, amounts, order.info.nonce, sig);
        if (sender != order.info.offerer) {
            revert InvalidSender();
        }
    }

    /// @notice Resolve order-type specific requirements into a generic order with the final inputs and outputs.
    /// @param order The encoded order to resolve
    /// @return resolvedOrder generic resolved order of inputs and outputs
    /// @dev should revert on any order-type-specific validation errors
    function resolve(bytes memory order) internal view virtual returns (ResolvedOrder memory resolvedOrder);
}