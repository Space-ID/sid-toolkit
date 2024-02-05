// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {DiscountHook} from "./DiscountHook.sol";
import {PreRegistrationState} from "../preregistration/PreRegistrationState.sol";
import {IPlatformConfig} from "../admin/IPlatformConfig.sol";
import {GiftCardLedger} from "../giftcard/GiftCardLedger.sol";
import {ISANN} from "../admin/ISANN.sol";
import {IPriceOracle} from "../price-oracle/IPriceOracle.sol";
import {StringUtils} from "../common/StringUtils.sol";

/**
 *@dev 1.when extending any domains, the renew fee will always be the same per year and the price is adjustable by the domain owner.
 *     2. can set preRegistration discount rate for each length of name during preRegistration period.
 *
 */

contract RenewDiscountHook is DiscountHook {
    using StringUtils for *;

    uint256 public constant ONE_YEAR = 31556952;
    uint256 public renewFee;

    constructor(
        ISANN _sann,
        uint256 _identifier,
        PreRegistrationState _state,
        IPlatformConfig _config,
        GiftCardLedger _ledger,
        IPriceOracle _priceOracle,
        uint16[] memory _preRegiDiscountRateBps,
        uint256 _publicRegistrationStartTime,
        uint256 _renewFee
    )
        DiscountHook(
            _sann,
            _identifier,
            _state,
            _config,
            _ledger,
            _priceOracle,
            _preRegiDiscountRateBps,
            _publicRegistrationStartTime
        )
    {
        renewFee = _renewFee;
    }

    function setRenewFee(uint256 _renewFee) public onlyTldOwner(identifier) {
        renewFee = _renewFee;
    }

    function _calcNewRenewPrice(
        uint256 _identifier,
        string calldata _name,
        address _buyer,
        uint256 _duration,
        uint256 _cost
    ) internal view override returns (uint256) {
        return renewFee * _duration;
    }

    // to apply preRegistration discount
    function _calcNewPrice(
        uint256 _identifier,
        string calldata _name,
        address _buyer,
        uint256 _duration,
        uint256 _cost
    ) internal view override returns (uint256 _newCost) {
        if (_duration > ONE_YEAR) {
            _newCost =
                ((_cost / _duration) * ONE_YEAR) +
                ((_duration - ONE_YEAR) * renewFee);
            _cost = (_cost / _duration) * ONE_YEAR; // for preRegistration discount
        } else {
            _newCost = _cost;
        }

        // name reserving logic
        // tldOwner can register names freely
        // before preRegistration and publicRegistration
        if (sann.tldOwner(identifier) == _buyer) {
            if (block.timestamp < publicRegistrationStartTime) {
                if (address(preRegiState) != address(0)) {
                    uint256 preRegiStartTime = preRegiState
                        .preRegistrationStartTime();
                    if (
                        (preRegiStartTime == 0) ||
                        (block.timestamp < preRegiStartTime)
                    ) {
                        return 0;
                    }
                } else {
                    return 0;
                }
            }
        }

        if (address(preRegiState) != address(0)) {
            // in preRegistartion, use preRegi discount
            if (preRegiState.inPreRegistration()) {
                uint8 letter = uint8(_name.strlen());
                if (letter > 5) {
                    letter = 5;
                }
                uint16 rateBps = preRegiDiscountRateBps[letter];
                uint256 _discount = ((_cost * rateBps) / MAX_RATE_BPS);
                // no platform fee credits
                _newCost -= _discount;
            }
        }
    }

    function _calcAuctionExemptation(
        uint256 _identifier,
        string calldata _name,
        address _buyer,
        uint256 _duration,
        uint256 _cost
    ) internal view override returns (uint256 _discount, uint256 _deductible) {
        if (address(preRegiState) != address(0)) {
            if (preRegiState.inRetentionPeriod()) {
                uint256 tokenID = uint256(keccak256(bytes(_name)));
                (, address winner, ) = preRegiState.auctionStatus(tokenID);
                if (winner == _buyer) {
                    // get winner's bidded value to cal prepaid platform fee
                    // in the auction
                    {
                        uint256 bidAmountInWei = preRegiState.bidAmount(
                            tokenID,
                            _buyer
                        );
                        uint256 bidAmount = priceOracle.weiToAttoUSD(
                            bidAmountInWei
                        );
                        // we will deduct all the paid platform fee in the auction
                        // even if the duration of the register is less than auction duration
                        _deductible += platformConfig.computeBasicPlatformFee(
                            _identifier,
                            bidAmount
                        );
                    }

                    // cal exempted price
                    uint256 auctionDuration = preRegiState
                        .auctionMinRegistrationDuration(); //@notice assume min duration is greater or equal to 1 year
                    // if duration of this pregistration is shorter than auctionMinRegistrationDuration
                    // then all cost will be exempted
                    if (_duration <= auctionDuration) {
                        return (_cost, _deductible);
                    }

                    _discount = _getAuctionDiscount(
                        _identifier,
                        _name,
                        _buyer,
                        auctionDuration
                    );
                }
            }
        }
    }

    function _getAuctionDiscount(
        uint256 _identifier,
        string calldata _name,
        address _buyer,
        uint256 _actionDuration
    ) internal view returns (uint256 _discount) {
        _discount = priceOracle
            .price(_name, 0, _actionDuration, _identifier)
            .base;
        _discount = _calcNewPrice(
            _identifier,
            _name,
            _buyer,
            _actionDuration,
            _discount
        );
    }
}
