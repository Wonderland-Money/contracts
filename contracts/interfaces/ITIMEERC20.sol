pragma solidity 0.7.5;
import './IERC20.sol';

interface IERC20Mintable {
  function mint( uint256 amount_ ) external;

  function mint( address account_, uint256 ammount_ ) external;
}

interface ITIMEERC20 is IERC20Mintable, IERC20 {
    function burnFrom(address account_, uint256 amount_) external;
}