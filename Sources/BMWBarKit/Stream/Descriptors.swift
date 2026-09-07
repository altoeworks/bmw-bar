import Foundation

/// BMW's telematic descriptor ids, as used by both the REST container and the stream.
///
/// **Every id here must exist in BMW's published catalogue.** Creating a container with
/// an unknown or deprecated id fails the whole request with
/// `CU-402 Telematic key is invalid`, so `DescriptorCatalogueTests` pins these against
/// a checked-in copy of the catalogue (`Scripts/fetch-catalogue.sh` refreshes it).
public enum Descriptor {
    // Battery / charge level
    public static let socHeader = "vehicle.drivetrain.batteryManagement.header"
    public static let socDisplayed = "vehicle.powertrain.electric.battery.stateOfCharge.displayed"
    /// The charge limit set in the car. Readable, but not settable — BMW's API has no
    /// write endpoint for it.
    public static let socTarget = "vehicle.powertrain.electric.battery.stateOfCharge.target"
    public static let maxEnergy = "vehicle.drivetrain.batteryManagement.maxEnergy"
    public static let batterySizeMax = "vehicle.drivetrain.batteryManagement.batterySizeMax"

    // Charging session.
    //
    // BMW publishes two status descriptors with *different* vocabularies:
    //   status:   NOCHARGING, INITIALIZATION, CHARGINGACTIVE, CHARGINGPAUSED,
    //             CHARGINGENDED, CHARGINGERROR, CHARGINGINTERRUPTED,
    //             CHARGINGDISRUPTED, UNKNOWN
    //   hvStatus: INVALID, CHARGING, ERROR, NOT_CHARGING, WAITING_FOR_CHARGING,
    //             FINISHED_FULLY_CHARGED, FINISHED_NOT_FULL
    // Both are subscribed to, and `ChargingStatus` understands either.
    public static let chargingStatus = "vehicle.drivetrain.electricEngine.charging.status"
    public static let chargingHVStatus = "vehicle.drivetrain.electricEngine.charging.hvStatus"
    /// Charging power, in **watts** (int32).
    public static let chargingPower = "vehicle.powertrain.electric.battery.charging.power"
    /// Minutes remaining, capped at 200 by BMW.
    public static let chargingTimeRemaining = "vehicle.drivetrain.electricEngine.charging.timeRemaining"
    /// Minutes to full — wider range than `chargingTimeRemaining`, so it is the
    /// fallback for long sessions.
    public static let chargingTimeToFull = "vehicle.drivetrain.electricEngine.charging.timeToFullyCharged"
    /// kWh still needed to reach a full pack.
    public static let energyToFull = "vehicle.drivetrain.electricEngine.charging.smeEnergyDeltaFullyCharged"
    public static let chargingACVoltage = "vehicle.drivetrain.electricEngine.charging.acVoltage"
    public static let chargingACAmpere = "vehicle.drivetrain.electricEngine.charging.acAmpere"
    public static let chargingPhases = "vehicle.drivetrain.electricEngine.charging.phaseNumber"
    /// The AC current limit selected in the car, in amps. Readable only.
    public static let acLimitSelected = "vehicle.powertrain.electric.battery.charging.acLimit.selected"

    /// Plug type actually in use: AC_TYPE1PLUG / AC_TYPE2PLUG / NOCHARGING.
    public static let chargingMethod = "vehicle.drivetrain.electricEngine.charging.method"

    // Plug / port
    public static let plugged = "vehicle.powertrain.tractionBattery.charging.port.anyPosition.isPlugged"
    /// CONNECTED, DISCONNECTED, INVALID, -NA-
    public static let chargingPortStatus = "vehicle.body.chargingPort.status"
    /// Whether the plug releases itself once charging finishes. A vehicle setting, not
    /// a live state — `true` means it unlocks automatically.
    public static let plugAutoUnlock = "vehicle.body.chargingPort.isHospitalityActive"

    // Range & efficiency
    public static let electricRange = "vehicle.drivetrain.electricEngine.kombiRemainingElectricRange"
    /// The range the i4 actually streams.
    ///
    /// BMW's catalogue lists this as ICE/PHEV/MHEV only, yet a BEV i4 sends it while
    /// the "BEV-correct" `kombiRemainingElectricRange` stays silent — the catalogue's
    /// `vehicletypes` field is not reliable, so both are subscribed.
    public static let lastRemainingRange = "vehicle.drivetrain.lastRemainingRange"
    /// Range you'd have at the configured target SoC.
    public static let rangeAtTarget = "vehicle.powertrain.electric.range.target"
    public static let avgConsumption = "vehicle.drivetrain.avgElectricRangeConsumption"

    /// Odometer. Note the doubled `vehicle.vehicle` — BMW's own namespacing.
    public static let mileage = "vehicle.vehicle.travelledDistance"

    // MARK: - Openings
    //
    // There is no central door-lock descriptor in BMW's catalogue: only the trunk and
    // the charge flap report lock state. `alarmArmStatus` is the honest proxy for
    // "locked", since BMW arms the alarm on locking — the UI says "Armed", not
    // "Locked".
    public static let doorFrontLeft = "vehicle.cabin.door.row1.driver.isOpen"
    public static let doorFrontRight = "vehicle.cabin.door.row1.passenger.isOpen"
    public static let doorRearLeft = "vehicle.cabin.door.row2.driver.isOpen"
    public static let doorRearRight = "vehicle.cabin.door.row2.passenger.isOpen"
    public static let trunkOpen = "vehicle.body.trunk.isOpen"
    public static let trunkLocked = "vehicle.body.trunk.isLocked"
    public static let hoodOpen = "vehicle.body.hood.isOpen"
    public static let chargeFlapLocked = "vehicle.body.flap.isLocked"

    /// CLOSED / INTERMEDIATE / OPEN / INVALID
    public static let windowFrontLeft = "vehicle.cabin.window.row1.driver.status"
    public static let windowFrontRight = "vehicle.cabin.window.row1.passenger.status"
    public static let windowRearLeft = "vehicle.cabin.window.row2.driver.status"
    public static let windowRearRight = "vehicle.cabin.window.row2.passenger.status"
    public static let rearWindowOpen = "vehicle.body.trunk.window.isOpen"

    // MARK: - Alarm
    /// unarmed / doorsOnly / doorsTiltCabin
    public static let alarmArmStatus = "vehicle.vehicle.antiTheftAlarmSystem.alarm.armStatus"
    public static let alarmIsOn = "vehicle.vehicle.antiTheftAlarmSystem.alarm.isOn"

    // MARK: - Tyres (pressures in kPa; 100 kPa = 1 bar)
    public static let tyreFrontLeftPressure = "vehicle.chassis.axle.row1.wheel.left.tire.pressure"
    public static let tyreFrontRightPressure = "vehicle.chassis.axle.row1.wheel.right.tire.pressure"
    public static let tyreRearLeftPressure = "vehicle.chassis.axle.row2.wheel.left.tire.pressure"
    public static let tyreRearRightPressure = "vehicle.chassis.axle.row2.wheel.right.tire.pressure"
    public static let tyreFrontLeftTarget = "vehicle.chassis.axle.row1.wheel.left.tire.pressureTarget"
    public static let tyreFrontRightTarget = "vehicle.chassis.axle.row1.wheel.right.tire.pressureTarget"
    public static let tyreRearLeftTarget = "vehicle.chassis.axle.row2.wheel.left.tire.pressureTarget"
    public static let tyreRearRightTarget = "vehicle.chassis.axle.row2.wheel.right.tire.pressureTarget"
    public static let tyreFrontLeftTemperature = "vehicle.chassis.axle.row1.wheel.left.tire.temperature"
    public static let tyreFrontRightTemperature = "vehicle.chassis.axle.row1.wheel.right.tire.temperature"
    public static let tyreRearLeftTemperature = "vehicle.chassis.axle.row2.wheel.left.tire.temperature"
    public static let tyreRearRightTemperature = "vehicle.chassis.axle.row2.wheel.right.tire.temperature"

    // MARK: - Location
    public static let latitude = "vehicle.cabin.infotainment.navigation.currentLocation.latitude"
    public static let longitude = "vehicle.cabin.infotainment.navigation.currentLocation.longitude"
    public static let heading = "vehicle.cabin.infotainment.navigation.currentLocation.heading"
    public static let altitude = "vehicle.cabin.infotainment.navigation.currentLocation.altitude"
    public static let gpsFixStatus = "vehicle.cabin.infotainment.navigation.currentLocation.fixStatus"

    // MARK: - Preconditioning
    //
    // BMW publishes only a *target* temperature, never an ambient or cabin reading, so
    // heating and cooling cannot be told apart. The UI uses one accent for both.
    /// OFF / ON_LEGACY / MANUAL_ON_CHARGE / AUTOMATIC_ON / REMOTE_ON_CHARGE /
    /// REMOTE_ON_DRIVE / REMOTE_OFF / UNKNOWN
    public static let preconditioningState = "vehicle.powertrain.electric.battery.preconditioning.state"
    public static let preconditioningManual = "vehicle.powertrain.electric.battery.preconditioning.manualMode.statusFeedback"
    public static let preconditioningAuto = "vehicle.powertrain.electric.battery.preconditioning.automaticMode.statusFeedback"
    public static let targetTemperature = "vehicle.cabin.hvac.preconditioning.configuration.defaultSettings.targetTemperature"

    // MARK: - Last trip
    public static let tripEndTime = "vehicle.trip.segment.end.time"
    public static let tripEndDistance = "vehicle.trip.segment.end.travelledDistance"
    public static let tripEndSoC = "vehicle.trip.segment.end.drivetrain.batteryManagement.hvSoc"
    public static let tripConsumption = "vehicle.trip.segment.accumulated.drivetrain.electricEngine.energyConsumptionComfort"
    public static let tripRecuperation = "vehicle.trip.segment.accumulated.drivetrain.electricEngine.recuperationTotal"
    public static let tripElectricFraction = "vehicle.trip.segment.accumulated.drivetrain.transmission.setting.fractionDriveElectric"

    public static let doors = [doorFrontLeft, doorFrontRight, doorRearLeft, doorRearRight]
    public static let windows = [windowFrontLeft, windowFrontRight, windowRearLeft, windowRearRight]
    /// Front-left, front-right, rear-left, rear-right — matched to their targets.
    public static let tyrePressures = [
        tyreFrontLeftPressure, tyreFrontRightPressure, tyreRearLeftPressure, tyreRearRightPressure,
    ]
    public static let tyreTargets = [
        tyreFrontLeftTarget, tyreFrontRightTarget, tyreRearLeftTarget, tyreRearRightTarget,
    ]
    public static let tyreTemperatures = [
        tyreFrontLeftTemperature, tyreFrontRightTemperature,
        tyreRearLeftTemperature, tyreRearRightTemperature,
    ]

    /// Everything the app subscribes to, for container creation.
    public static let all: [String] = [
        socHeader, socDisplayed, socTarget, maxEnergy, batterySizeMax,
        chargingStatus, chargingHVStatus, chargingPower,
        chargingTimeRemaining, chargingTimeToFull, energyToFull,
        chargingACVoltage, chargingACAmpere, chargingPhases, acLimitSelected,
        chargingMethod, plugged, chargingPortStatus, plugAutoUnlock,
        electricRange, lastRemainingRange, rangeAtTarget, avgConsumption, mileage,
    ]
        + doors + windows + [rearWindowOpen, trunkOpen, trunkLocked, hoodOpen, chargeFlapLocked]
        + [alarmArmStatus, alarmIsOn]
        + tyrePressures + tyreTargets + tyreTemperatures
        + [latitude, longitude, heading, altitude, gpsFixStatus]
        + [preconditioningState, preconditioningManual, preconditioningAuto, targetTemperature]
        + [tripEndTime, tripEndDistance, tripEndSoC, tripConsumption, tripRecuperation, tripElectricFraction]

    /// Short label for CLI output and the detail panel.
    public static func label(for id: String) -> String {
        labels[id] ?? id
    }

    private static let labels: [String: String] = [
        socHeader: "Charge level",
        socDisplayed: "Charge level (displayed)",
        socTarget: "Charge limit",
        maxEnergy: "Usable capacity",
        batterySizeMax: "Pack capacity",
        chargingStatus: "Charging status",
        chargingHVStatus: "Charging status (HV)",
        chargingPower: "Charging power",
        chargingTimeRemaining: "Time remaining",
        chargingTimeToFull: "Time to full",
        energyToFull: "Energy to full",
        chargingACVoltage: "AC voltage",
        chargingACAmpere: "AC current",
        chargingPhases: "Phases",
        acLimitSelected: "AC current limit",
        plugged: "Plugged in",
        chargingPortStatus: "Charging port",
        chargingMethod: "Charging plug",
        plugAutoUnlock: "Plug auto-unlock",
        electricRange: "Electric range",
        lastRemainingRange: "Range (last sent)",
        rangeAtTarget: "Range at limit",
        avgConsumption: "Avg consumption",
        mileage: "Odometer",
        doorFrontLeft: "Door front left",
        doorFrontRight: "Door front right",
        doorRearLeft: "Door rear left",
        doorRearRight: "Door rear right",
        trunkOpen: "Boot",
        trunkLocked: "Boot lock",
        hoodOpen: "Bonnet",
        chargeFlapLocked: "Charge flap lock",
        windowFrontLeft: "Window front left",
        windowFrontRight: "Window front right",
        windowRearLeft: "Window rear left",
        windowRearRight: "Window rear right",
        rearWindowOpen: "Rear window",
        alarmArmStatus: "Alarm",
        alarmIsOn: "Alarm triggered",
        tyreFrontLeftPressure: "Tyre front left",
        tyreFrontRightPressure: "Tyre front right",
        tyreRearLeftPressure: "Tyre rear left",
        tyreRearRightPressure: "Tyre rear right",
        tyreFrontLeftTarget: "Tyre target front left",
        tyreFrontRightTarget: "Tyre target front right",
        tyreRearLeftTarget: "Tyre target rear left",
        tyreRearRightTarget: "Tyre target rear right",
        tyreFrontLeftTemperature: "Tyre temp front left",
        tyreFrontRightTemperature: "Tyre temp front right",
        tyreRearLeftTemperature: "Tyre temp rear left",
        tyreRearRightTemperature: "Tyre temp rear right",
        latitude: "Latitude",
        longitude: "Longitude",
        heading: "Heading",
        altitude: "Altitude",
        gpsFixStatus: "GPS fix",
        preconditioningState: "Preconditioning",
        preconditioningManual: "Preconditioning (manual)",
        preconditioningAuto: "Preconditioning (auto)",
        targetTemperature: "Target temperature",
        tripEndTime: "Last trip ended",
        tripEndDistance: "Odometer after trip",
        tripEndSoC: "Charge after trip",
        tripConsumption: "Trip consumption",
        tripRecuperation: "Trip recuperation",
        tripElectricFraction: "Electric share",
    ]
}

/// The charging states BMW reports.
///
/// Two descriptors use two different vocabularies (see `Descriptor.chargingStatus`), so
/// both are accepted. Unrecognised values are preserved rather than flattened, since
/// BMW extends these enums.
public enum ChargingStatus: Equatable, Sendable {
    case charging
    case notCharging
    case initialising
    /// Interrupted mid-session and expected to resume.
    case paused
    /// Session finished without reaching a full pack — typically the charge limit.
    case ended
    case complete
    case waiting
    case error
    case unknown(String)

    public init(raw: String) {
        let normalised = raw.uppercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch normalised {
        case "CHARGINGACTIVE", "CHARGING", "ACTIVE":
            self = .charging
        case "NOCHARGING", "NOTCHARGING", "INACTIVE":
            self = .notCharging
        case "INITIALIZATION", "INITIALISATION":
            self = .initialising
        case "CHARGINGPAUSED", "CHARGINGINTERRUPTED", "CHARGINGDISRUPTED", "PAUSED":
            self = .paused
        case "CHARGINGENDED", "FINISHEDNOTFULL":
            self = .ended
        case "FINISHEDFULLYCHARGED", "COMPLETE", "COMPLETED", "FULLYCHARGED":
            self = .complete
        case "WAITINGFORCHARGING", "PLUGGEDIN", "TARGETREACHED":
            self = .waiting
        case "CHARGINGERROR", "ERROR", "FAULT":
            self = .error
        default:
            self = .unknown(raw)
        }
    }

    public var isActivelyCharging: Bool { self == .charging }

    /// Whether this value says anything useful. `UNKNOWN` / `INVALID` do not, so a
    /// second descriptor should be preferred over them.
    public var isInformative: Bool {
        switch self {
        case .unknown(let raw):
            let normalised = raw.uppercased()
            return normalised != "UNKNOWN" && normalised != "INVALID" && normalised != "-NA-"
        default:
            return true
        }
    }

    public var displayName: String {
        switch self {
        case .charging: return "Charging"
        case .notCharging: return "Not charging"
        case .initialising: return "Starting charge"
        case .paused: return "Charging paused"
        case .ended: return "Charging ended"
        case .complete: return "Charge complete"
        case .waiting: return "Waiting to charge"
        case .error: return "Charging error"
        case .unknown(let raw): return raw.capitalized
        }
    }
}
