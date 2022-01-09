// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;
import './interfaces/IERC20.sol';
import './interfaces/IStaking.sol';


contract StakingHelper {

    event LogStake(address indexed recipient, uint amount);

    IStaking public immutable staking;
    IERC20 public immutable Time;

    constructor ( address _staking, address _Time ) {
        require( _staking != address(0) );
        staking = IStaking(_staking);
        require( _Time != address(0) );
        Time = IERC20(_Time);
    }

    function stake( uint _amount, address recipient ) external {
        Time.transferFrom( msg.sender, address(this), _amount );
        Time.approve( address(staking), _amount );
        staking.stake( _amount, recipient );
        staking.claim( recipient );
        emit LogStake(recipient, _amount);
    }
}