// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity 0.7.5;
import './libraries/Ownable.sol';
import './libraries/LowGasSafeMath.sol';
import './libraries/Address.sol';
import './interfaces/IERC20.sol';
import './interfaces/ITreasury.sol';


contract Distributor is Ownable {
    using LowGasSafeMath for uint;
    using LowGasSafeMath for uint32;
    
    
    
    /* ====== VARIABLES ====== */

    IERC20 public immutable TIME;
    ITreasury public immutable treasury;
    
    uint32 public immutable epochLength;
    uint32 public nextEpochTime;
    
    mapping( uint => Adjust ) public adjustments;

    event LogDistribute(address indexed recipient, uint amount);
    event LogAdjust(uint initialRate, uint currentRate, uint targetRate);
    event LogAddRecipient(address indexed recipient, uint rate);
    event LogRemoveRecipient(address indexed recipient);
    
    /* ====== STRUCTS ====== */
        
    struct Info {
        uint rate; // in ten-thousandths ( 5000 = 0.5% )
        address recipient;
    }
    Info[] public info;
    
    struct Adjust {
        bool add;
        uint rate;
        uint target;
    }
    
    
    
    /* ====== CONSTRUCTOR ====== */

    constructor( address _treasury, address _time, uint32 _epochLength, uint32 _nextEpochTime ) {        
        require( _treasury != address(0) );
        treasury = ITreasury(_treasury);
        require( _time != address(0) );
        TIME = IERC20(_time);
        epochLength = _epochLength;
        nextEpochTime = _nextEpochTime;
    }
    
    
    
    /* ====== PUBLIC FUNCTIONS ====== */
    
    /**
        @notice send epoch reward to staking contract
     */
    function distribute() external returns ( bool ) {
        if ( nextEpochTime <= uint32(block.timestamp) ) {
            nextEpochTime = nextEpochTime.add32( epochLength ); // set next epoch time
            
            // distribute rewards to each recipient
            for ( uint i = 0; i < info.length; i++ ) {
                if ( info[ i ].rate > 0 ) {
                    treasury.mintRewards( // mint and send from treasury
                        info[ i ].recipient, 
                        nextRewardAt( info[ i ].rate ) 
                    );
                    adjust( i ); // check for adjustment
                }
                emit LogDistribute(info[ i ].recipient, nextRewardAt( info[ i ].rate ));
            }
            return true;
        } else { 
            return false; 
        }
    }
    
    
    
    /* ====== INTERNAL FUNCTIONS ====== */

    /**
        @notice increment reward rate for collector
     */
    function adjust( uint _index ) internal {
        Adjust memory adjustment = adjustments[ _index ];
        if ( adjustment.rate != 0 ) {
            uint initial = info[ _index ].rate;
            uint rate = initial;
            if ( adjustment.add ) { // if rate should increase
                rate = rate.add( adjustment.rate ); // raise rate
                if ( rate >= adjustment.target ) { // if target met
                    rate = adjustment.target;
                    delete adjustments[ _index ];
                }
            } else { // if rate should decrease
                rate = rate.sub( adjustment.rate ); // lower rate
                if ( rate <= adjustment.target ) { // if target met
                    rate = adjustment.target;
                    delete adjustments[ _index ];
                }
            }
            info[ _index ].rate = rate;
            emit LogAdjust(initial, rate, adjustment.target);
        }
    }
    
    
    
    /* ====== VIEW FUNCTIONS ====== */

    /**
        @notice view function for next reward at given rate
        @param _rate uint
        @return uint
     */
    function nextRewardAt( uint _rate ) public view returns ( uint ) {
        return TIME.totalSupply().mul( _rate ).div( 1000000 );
    }

    /**
        @notice view function for next reward for specified address
        @param _recipient address
        @return uint
     */
    function nextRewardFor( address _recipient ) external view returns ( uint ) {
        uint reward;
        for ( uint i = 0; i < info.length; i++ ) {
            if ( info[ i ].recipient == _recipient ) {
                reward = nextRewardAt( info[ i ].rate );
            }
        }
        return reward;
    }
    
    
    
    /* ====== POLICY FUNCTIONS ====== */

    /**
        @notice adds recipient for distributions
        @param _recipient address
        @param _rewardRate uint
     */
    function addRecipient( address _recipient, uint _rewardRate ) external onlyOwner {
        require( _recipient != address(0), "IA" );
        require(_rewardRate <= 5000, "Too high reward rate");
        require(info.length <= 4, "limit recipients max to 5");
        info.push( Info({
            recipient: _recipient,
            rate: _rewardRate
        }));
        emit LogAddRecipient(_recipient, _rewardRate);
    }

    /**
        @notice removes recipient for distributions
        @param _index uint
        @param _recipient address
     */
    function removeRecipient( uint _index, address _recipient ) external onlyOwner {
        require( _recipient == info[ _index ].recipient, "NA" );
        info[_index] = info[info.length-1];
        adjustments[_index] = adjustments[ info.length-1 ];
        info.pop();
        delete adjustments[ info.length-1 ];
        emit LogRemoveRecipient(_recipient);
    }

    /**
        @notice set adjustment info for a collector's reward rate
        @param _index uint
        @param _add bool
        @param _rate uint
        @param _target uint
     */
    function setAdjustment( uint _index, bool _add, uint _rate, uint _target ) external onlyOwner {
        require(_target <= 5000, "Too high reward rate");
        adjustments[ _index ] = Adjust({
            add: _add,
            rate: _rate,
            target: _target
        });
    }
}