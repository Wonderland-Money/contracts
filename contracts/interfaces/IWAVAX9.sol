pragma solidity 0.7.5;
import './IERC20.sol';

interface IWAVAX9 is IERC20 {
    /// @notice Deposit ether to get wrapped ether
    function deposit() external payable;
}