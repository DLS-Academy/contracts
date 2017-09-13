pragma solidity ^0.4.11;

/*
    Copyright 2017, Larry (Decentralized Learning System)
*/

import "./MiniMeToken.sol";

contract DLT is MiniMeToken {
    // @dev DLT constructor just parametrizes the MiniMeToken constructor
    function DLT(address _tokenFactory)
        MiniMeToken(
            _tokenFactory,
            0x0,
            0,
            "Decentralized Learning Token",
            18,
            "DLT",
            true
        ) {}
}
