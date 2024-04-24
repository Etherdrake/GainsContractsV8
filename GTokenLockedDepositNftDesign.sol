// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import "../interfaces/IGTokenLockedDepositNftDesign.sol";

/**
 * @custom:version 6.3
 */
contract GTokenLockedDepositNftDesign is IGTokenLockedDepositNftDesign {
    function buildTokenURI(
        uint256 tokenId,
        IGToken.LockedDeposit memory lockedDeposit,
        string memory gTokenSymbol,
        string memory assetSymbol,
        uint8 numberInputDecimals,
        uint8 numberOutputDecimals
    ) external pure returns (string memory) {
        return
            string(
                abi.encodePacked(
                    "data:application/json;base64,",
                    Base64.encode(
                        abi.encodePacked(
                            '{"name":"',
                            gTokenSymbol,
                            ' Locked Deposit", "image":"data:image/svg+xml;base64,',
                            generateBase64Image(
                                tokenId,
                                lockedDeposit,
                                gTokenSymbol,
                                assetSymbol,
                                numberInputDecimals,
                                numberOutputDecimals
                            ),
                            '", "description": "This NFT represents locked ',
                            gTokenSymbol,
                            '."}'
                        )
                    )
                )
            );
    }

    // TODO: design will evolve
    function generateBase64Image(
        uint256 tokenId,
        IGToken.LockedDeposit memory lockedDeposit,
        string memory gTokenSymbol,
        string memory assetSymbol,
        uint8 numberInputDecimals,
        uint8 numberOutputDecimals
    ) private pure returns (string memory) {
        return
            Base64.encode(
                bytes.concat(
                    abi.encodePacked(
                        '<?xml version="1.0" encoding="UTF-8"?>',
                        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" version="1.1" ',
                        'viewBox="0 0 400 300" preserveAspectRatio="xMidYMid meet">',
                        '<style type="text/css"><![CDATA[text { font-family: Lato; font-size: 12px;}]]></style>',
                        '<rect width="400" height="300" fill="#ffffff" />',
                        '<text x="20" y="35"><tspan style="font-weight: 600">Token ID: </tspan>',
                        Strings.toString(tokenId),
                        '</text><text x="20" y="75"><tspan style="font-weight: 600">Depositor: </tspan>',
                        Strings.toHexString(uint256(uint160(lockedDeposit.owner)), 20),
                        "</text>"
                    ),
                    abi.encodePacked(
                        '<text x="20" y="115"><tspan style="font-weight: 600">Shares: </tspan>',
                        numberToRoundedString(lockedDeposit.shares, numberInputDecimals, numberOutputDecimals),
                        " ",
                        gTokenSymbol,
                        '</text><text x="20" y="155"><tspan style="font-weight: 600">Assets deposited: </tspan>',
                        numberToRoundedString(lockedDeposit.assetsDeposited, numberInputDecimals, numberOutputDecimals),
                        " ",
                        assetSymbol,
                        "</text>"
                    ),
                    abi.encodePacked(
                        '<text x="20" y="195"><tspan style="font-weight: 600">Assets discount: </tspan>',
                        numberToRoundedString(lockedDeposit.assetsDiscount, numberInputDecimals, numberOutputDecimals),
                        " ",
                        assetSymbol,
                        '</text><text x="20" y="235"><tspan style="font-weight: 600">Deposit timestamp: </tspan>',
                        Strings.toString(lockedDeposit.atTimestamp),
                        "</text>",
                        '<text x="20" y="275"><tspan style="font-weight: 600">Unlock timestamp: </tspan>',
                        Strings.toString(lockedDeposit.atTimestamp + lockedDeposit.lockDuration),
                        "</text></svg>"
                    )
                )
            );
    }

    // Returns readable string of integer part of number passed
    // TODO: make it return the string with decimals = 'outputDecimals'
    function numberToRoundedString(
        uint256 number,
        uint8 inputDecimals,
        uint8 outputDecimals
    ) public pure returns (string memory) {
        outputDecimals = 0; // silence warning
        return Strings.toString(number / (10 ** inputDecimals));
    }
}