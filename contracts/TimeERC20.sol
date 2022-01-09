// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;
import './libraries/LowGasSafeMath.sol';
import './abstracts/ERC20Permit.sol';
import './libraries/VaultOwned.sol';


contract TimeERC20Token is ERC20Permit, VaultOwned {

    using LowGasSafeMath for uint256;

    constructor() ERC20("Time", "TIME", 9) {
    }

    function mint(address account_, uint256 amount_) external onlyVault() {
        _mint(account_, amount_);
    }

    function burn(uint256 amount) external virtual {
        _burn(msg.sender, amount);
    }
     
    function burnFrom(address account_, uint256 amount_) external virtual {
        _burnFrom(account_, amount_);
    }

    function _burnFrom(address account_, uint256 amount_) internal virtual {
        uint256 decreasedAllowance_ =
            allowance(account_, msg.sender).sub(amount_);

        _approve(account_, msg.sender, decreasedAllowance_);
        _burn(account_, amount_);
    }
}