// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;
import './interfaces/IERC20.sol';

contract StakingWarmup {

    address public immutable staking;
    IERC20 public immutable MEMOries;

    constructor ( address _staking, address _MEMOries ) {
        require( _staking != address(0) );
        staking = _staking;
        require( _MEMOries != address(0) );
        MEMOries = IERC20(_MEMOries);
    }

    function retrieve( address _staker, uint _amount ) external {
        require( msg.sender == staking, "NA" );
        MEMOries.transfer( _staker, _amount );
    }
}