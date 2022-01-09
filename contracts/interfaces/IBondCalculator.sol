pragma solidity 0.7.5;

interface IBondCalculator {
    function valuation( address _LP, uint _amount ) external view returns ( uint );
    
    function markdown( address _LP ) external view returns ( uint );
}