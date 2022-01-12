// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockESW is ERC20 {
    constructor(uint256 init_supply) ERC20("ESW token", "ESW") {
        _mint(msg.sender, init_supply);
    }
}
