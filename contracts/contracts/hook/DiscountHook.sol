// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4;

import {TldAccessable} from "../access/TldAccessable.sol";
import {IPriceHook} from "../hook/IPriceHook.sol";
import {IRenewPriceHook} from "../hook/IRenewPriceHook.sol";
import {IPointHook} from "../hook/IPointHook.sol";
import {IRenewPointHook} from "../hook/IRenewPointHook.sol";
import {PreRegistrationState} from "../preregistration/PreRegistrationState.sol";
import {IPlatformConfig} from "../admin/IPlatformConfig.sol";
import {GiftCardLedger} from "../giftcard/GiftCardLedger.sol";
import {ISANN} from "../admin/ISANN.sol";
import {IPriceOracle} from "../price-oracle/IPriceOracle.sol";
import {HookExtraData} from "../common/Struct.sol";

error PublicRegistrationStarted();

abstract contract DiscountHook is
    TldAccessable,
    IPriceHook,
    IRenewPriceHook,
    IPointHook,
    IRenewPointHook
{

    PreRegistrationState public preRegiState;
    IPlatformConfig public platformConfig;
    GiftCardLedger public ledger;
    IPriceOracle public priceOracle;

    // identifier of TLD
    uint256 public immutable identifier;

    uint256 public constant MAX_RATE_BPS = 10000; // 100%
    // letter => peRegiDiscount
    mapping(uint8 => uint16) public preRegiDiscountRateBps;

    uint256 public publicRegistrationStartTime;

    event SetPreRegiDiscountRateBps(
        uint256 identifier,
        uint8 letter,
        uint16 discountRateBps
    );
    event SetPublicRegistrationStartTime(uint256 identifier, uint256 startTime);

    // point info which can be decoded from extraData
    struct PointInfo {
        bool useGiftCardPoints;
    }

    constructor(
        ISANN _sann,
        uint256 _identifier,
        PreRegistrationState _state,
        IPlatformConfig _config,
        GiftCardLedger _ledger,
        IPriceOracle _priceOracle,
        uint16[] memory _preRegiDiscountRateBps,
        uint256 _publicRegistrationStartTime
    ) TldAccessable(_sann) {
        identifier = _identifier;
        preRegiState = _state;
        platformConfig = _config;
        ledger = _ledger;
        priceOracle = _priceOracle;

        for (uint8 i = 0; i < _preRegiDiscountRateBps.length; i++) {
            uint16 bps = _preRegiDiscountRateBps[i];
            require(bps <= MAX_RATE_BPS, "invalid preRegiDiscountRateBps");
            preRegiDiscountRateBps[i] = bps;
            emit SetPreRegiDiscountRateBps(_identifier, i, bps);
        }

        publicRegistrationStartTime = _publicRegistrationStartTime;
        emit SetPublicRegistrationStartTime(
            identifier,
            _publicRegistrationStartTime
        );
    }

    //
    // for PriceHook
    //
    function calcNewPrice(
        uint256 _identifier,
        string calldata _name,
        address _buyer,
        uint256 _duration,
        uint256 _cost,
        bytes calldata _extraData
    ) external view returns (uint256) {
        return _calcNewPrice(_identifier, _name, _buyer, _duration, _cost);
    }

    function newPrice(
        uint256 _identifier,
        string calldata _name,
        address _buyer,
        uint256 _duration,
        uint256 _cost,
        bytes calldata _extraData
    ) external onlyTldController returns (uint256) {
        return _calcNewPrice(_identifier, _name, _buyer, _duration, _cost);
    }

    //
    // for RenewPriceHook
    //
    function calcRenewNewPrice(
        uint256 _identifier,
        string calldata _name,
        address _buyer,
        uint256 _duration,
        uint256 _cost,
        bytes calldata _extraData
    ) external view returns (uint256) {
        return _calcNewRenewPrice(_identifier, _name, _buyer, _duration, _cost);
    }

    function newRenewPrice(
        uint256 _identifier,
        string calldata _name,
        address _buyer,
        uint256 _duration,
        uint256 _cost,
        bytes calldata _extraData
    ) external onlyTldController returns (uint256) {
        return _calcNewRenewPrice(_identifier, _name, _buyer, _duration, _cost);
    }

    function _calcNewRenewPrice(
        uint256 _identifier,
        string calldata _name,
        address _buyer,
        uint256 _duration,
        uint256 _cost) internal view virtual returns (uint256);

    //
    // for PointHook
    //
    function calcDeduction(
        uint256 _identifier,
        string calldata _name,
        address _buyer,
        uint256 _duration,
        uint256 _cost,
        uint256 _platformFee,
        bytes calldata _extraData
    ) external view returns (uint256 _discount, uint256 _deductible) {
        bool useGiftCardPoints = false;
        if (_extraData.length > 0) {
            HookExtraData memory hookExtraData = abi.decode(
                _extraData,
                (HookExtraData)
            );
            if (hookExtraData.PointHookExtraData.length > 0) {
                PointInfo memory pointInfo = abi.decode(
                    hookExtraData.PointHookExtraData,
                    (PointInfo)
                );
                useGiftCardPoints = pointInfo.useGiftCardPoints;
            }
        }

        (_discount, _deductible, ) = _calcPoint(
            _identifier,
            _name,
            _buyer,
            _duration,
            _cost,
            useGiftCardPoints
        );
    }

    function deduct(
        uint256 _identifier,
        string calldata _name,
        address _buyer,
        uint256 _duration,
        uint256 _cost,
        uint256 _platformFee,
        bytes calldata _extraData
    )
        external
        onlyTldController
        returns (uint256 _discount, uint256 _deductible)
    {
        bool useGiftCardPoints = false;
        if (_extraData.length > 0) {
            HookExtraData memory hookExtraData = abi.decode(
                _extraData,
                (HookExtraData)
            );
            if (hookExtraData.PointHookExtraData.length > 0) {
                PointInfo memory pointInfo = abi.decode(
                    hookExtraData.PointHookExtraData,
                    (PointInfo)
                );
                useGiftCardPoints = pointInfo.useGiftCardPoints;
            }
        }

        uint256 pointUsed;
        (_discount, _deductible, pointUsed) = _calcPoint(
            _identifier,
            _name,
            _buyer,
            _duration,
            _cost,
            useGiftCardPoints
        );

        if (pointUsed > 0) {
            _deductGiftCardPoints(_buyer, pointUsed, _identifier);
        }
    }

    //
    // for RenewPointHook
    //
    function calcRenewDeduction(
        uint256 _identifier,
        string calldata _name,
        address _buyer,
        uint256 _duration,
        uint256 _cost,
        uint256 _platformFee,
        bytes calldata _extraData
    ) external view returns (uint256 _discount, uint256 _deductible) {
        bool useGiftCardPoints = false;
        if (_extraData.length > 0) {
            HookExtraData memory hookExtraData = abi.decode(
                _extraData,
                (HookExtraData)
            );
            if (hookExtraData.PointHookExtraData.length > 0) {
                PointInfo memory pointInfo = abi.decode(
                    hookExtraData.PointHookExtraData,
                    (PointInfo)
                );
                useGiftCardPoints = pointInfo.useGiftCardPoints;
            }
        }

        if (!useGiftCardPoints) {
            return (0, 0);
        }

        uint256 pointUsed;
        (pointUsed, _deductible) = _calcGiftCardPoint(
            _identifier,
            _name,
            _buyer,
            _duration,
            _cost
        );
        _discount = pointUsed;
    }

    function deductRenew(
        uint256 _identifier,
        string calldata _name,
        address _buyer,
        uint256 _duration,
        uint256 _cost,
        uint256 _platformFee,
        bytes calldata _extraData
    )
        external
        onlyTldController
        returns (uint256 _discount, uint256 _deductible)
    {
        bool useGiftCardPoints = false;
        if (_extraData.length > 0) {
            HookExtraData memory hookExtraData = abi.decode(
                _extraData,
                (HookExtraData)
            );
            if (hookExtraData.PointHookExtraData.length > 0) {
                PointInfo memory pointInfo = abi.decode(
                    hookExtraData.PointHookExtraData,
                    (PointInfo)
                );
                useGiftCardPoints = pointInfo.useGiftCardPoints;
            }
        }

        if (!useGiftCardPoints) {
            return (0, 0);
        }

        uint256 pointUsed;
        (pointUsed, _deductible) = _calcGiftCardPoint(
            _identifier,
            _name,
            _buyer,
            _duration,
            _cost
        );
        _discount = pointUsed;

        if (pointUsed > 0) {
            _deductGiftCardPoints(_buyer, pointUsed, _identifier);
        }
    }

    // to apply preRegistration discount
    function _calcNewPrice(
        uint256 _identifier,
        string calldata _name,
        address _buyer,
        uint256 _duration,
        uint256 _cost
    ) internal view virtual returns (uint256 _newCost);

    function _calcPoint(
        uint256 _identifier,
        string calldata _name,
        address _buyer,
        uint256 _duration,
        uint256 _cost,
        bool useGiftCardPoints
    )
        private
        view
        returns (uint256 _discount, uint256 _deductible, uint256 _pointUsed)
    {
        // auction winner can be exempted for minRegistrationDuration
        // if the name is still in the retention period
        (_discount, _deductible) = _calcAuctionExemptation(
            _identifier,
            _name,
            _buyer,
            _duration,
            _cost
        );

        // update cost
        if (_cost <= _discount) {
            return (_cost, _deductible, 0);
        }
        _cost -= _discount;

        // check giftcard points balance
        uint256 giftCardDeducitible;
        if (useGiftCardPoints) {
            (_pointUsed, giftCardDeducitible) = _calcGiftCardPoint(
                _identifier,
                _name,
                _buyer,
                _duration,
                _cost
            );
        }

        // sum all discounts and deductible platform fees
        _discount += _pointUsed;
        _deductible += giftCardDeducitible;
    }

    // to calc auction winner exemptation in registration
    function _calcAuctionExemptation(
        uint256 _identifier,
        string calldata _name,
        address _buyer,
        uint256 _duration,
        uint256 _cost
    ) internal view virtual returns (uint256 _discount, uint256 _deductible);

    function _calcGiftCardPoint(
        uint256 _identifier,
        string calldata _name,
        address _buyer,
        uint256 _duration,
        uint256 _cost
    ) private view returns (uint256 _pointUsed, uint256 _deductible) {
        uint256 pointRedemption = ledger.balanceOf(_identifier, _buyer);
        if (pointRedemption > _cost) {
            _pointUsed = _cost;
        } else {
            _pointUsed = pointRedemption;
        }
        if (_pointUsed > 0) {
            uint256 _paidPlatformFee = platformConfig.computeBasicPlatformFee(
                _identifier,
                _pointUsed
            );
            _deductible = _paidPlatformFee;
        }
    }

    function _deductGiftCardPoints(
        address _buyer,
        uint256 _pointUsed,
        uint256 _identifier
    ) private {
        // should add this hook as the ledger's controller
        ledger.deduct(_identifier, _buyer, _pointUsed);
    }

    /**
     * @dev To update preRegistration discount.
     *      Only can be called by TLD owner
     * @param letter The length of name
     * @param rateBps The new preRegistration discount bps
     */
    function setPreRegiDiscountRateBps(
        uint8 letter,
        uint16 rateBps
    ) public onlyTldOwner(identifier) {
        require(rateBps <= MAX_RATE_BPS, "invalid preRegiDiscountRateBps");
        preRegiDiscountRateBps[letter] = rateBps;
        emit SetPreRegiDiscountRateBps(identifier, letter, rateBps);
    }

    function setPublicRegistrationStartTime(
        uint256 _publicRegistrationStartTime
    ) public onlyTldOwner(identifier) onlyBeforePublicRegiStart {
        require(
            block.timestamp < _publicRegistrationStartTime,
            "new publicRegistrationStartTime must be greater than now"
        );

        uint256 preRegiEndTime = preRegiState.preRegistrationEndTime();
        require(
            preRegiEndTime < _publicRegistrationStartTime,
            "new publicRegistrationStartTime must be greater than preRegistrationEndTime"
        );

        publicRegistrationStartTime = _publicRegistrationStartTime;
        emit SetPublicRegistrationStartTime(
            identifier,
            _publicRegistrationStartTime
        );
    }

    modifier onlyBeforePublicRegiStart() {
        if (block.timestamp >= publicRegistrationStartTime) {
            revert PublicRegistrationStarted();
        }
        _;
    }
}
