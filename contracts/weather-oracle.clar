;; Weather Oracle Smart Contract
;; Fetches, validates, and stores weather data for agricultural insurance

;; Error codes
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INVALID_DATA (err u101))
(define-constant ERR_DATA_NOT_FOUND (err u102))
(define-constant ERR_ORACLE_EXISTS (err u103))
(define-constant ERR_INVALID_TIMESTAMP (err u104))
(define-constant ERR_INSUFFICIENT_STAKE (err u105))
(define-constant ERR_INVALID_LOCATION (err u106))
(define-constant ERR_DATA_TOO_OLD (err u107))

;; Constants
(define-constant ORACLE_STAKE_REQUIRED u1000000) ;; 1 STX in microSTX
(define-constant MAX_DATA_AGE u86400) ;; 24 hours in seconds
(define-constant MIN_ORACLES_FOR_CONSENSUS u3)
(define-constant CONSENSUS_THRESHOLD u66) ;; 66% agreement required

;; Data variables
(define-data-var contract-owner principal tx-sender)
(define-data-var oracle-count uint u0)
(define-data-var data-submission-count uint u0)

;; Weather data structure
(define-map weather-data
  { location: { latitude: int, longitude: int }, timestamp: uint }
  {
    temperature: int, ;; Celsius * 100 (for precision)
    rainfall: uint, ;; mm * 100
    humidity: uint, ;; percentage
    wind-speed: uint, ;; km/h * 100
    pressure: uint, ;; hPa * 100
    submitter: principal,
    submission-time: uint,
    validated: bool
  }
)

;; Oracle registry
(define-map authorized-oracles
  { oracle: principal }
  {
    stake-amount: uint,
    reputation-score: uint,
    total-submissions: uint,
    correct-submissions: uint,
    registration-time: uint,
    is-active: bool
  }
)

;; Location weather history
(define-map location-history
  { location: { latitude: int, longitude: int } }
  {
    last-update: uint,
    total-records: uint,
    average-temperature: int,
    total-rainfall: uint
  }
)

;; Data validation consensus
(define-map data-consensus
  { data-hash: (buff 32) }
  {
    submissions: uint,
    agreement-count: uint,
    finalized: bool,
    consensus-reached: bool
  }
)

;; Oracle staking map
(define-map oracle-stakes
  { oracle: principal }
  { amount: uint, locked-until: uint }
)

;; Read-only functions

(define-read-only (get-weather-data (location { latitude: int, longitude: int }) (timestamp uint))
  (map-get? weather-data { location: location, timestamp: timestamp })
)

(define-read-only (get-oracle-info (oracle principal))
  (map-get? authorized-oracles { oracle: oracle })
)

(define-read-only (get-location-history (location { latitude: int, longitude: int }))
  (map-get? location-history { location: location })
)

(define-read-only (is-oracle-authorized (oracle principal))
  (match (map-get? authorized-oracles { oracle: oracle })
    oracle-data (get is-active oracle-data)
    false
  )
)

(define-read-only (get-contract-stats)
  {
    total-oracles: (var-get oracle-count),
    total-submissions: (var-get data-submission-count),
    owner: (var-get contract-owner)
  }
)

(define-read-only (validate-location (location { latitude: int, longitude: int }))
  (and
    (and (>= (get latitude location) -9000) (<= (get latitude location) 9000))
    (and (>= (get longitude location) -18000) (<= (get longitude location) 18000))
  )
)

(define-read-only (is-data-fresh (timestamp uint))
  (<= (- block-height timestamp) MAX_DATA_AGE)
)

(define-read-only (calculate-average-temperature (location { latitude: int, longitude: int }) (days uint))
  (let (
    (history (default-to 
      { last-update: u0, total-records: u0, average-temperature: 0, total-rainfall: u0 }
      (map-get? location-history { location: location })
    ))
  )
    (if (> (get total-records history) u0)
      (some (get average-temperature history))
      none
    )
  )
)

;; Public functions

(define-public (register-oracle)
  (let (
    (oracle tx-sender)
    (existing (map-get? authorized-oracles { oracle: oracle }))
  )
    (asserts! (is-none existing) ERR_ORACLE_EXISTS)
    (try! (stx-transfer? ORACLE_STAKE_REQUIRED tx-sender (as-contract tx-sender)))
    (map-set oracle-stakes { oracle: oracle } { amount: ORACLE_STAKE_REQUIRED, locked-until: (+ block-height u144) })
    (map-set authorized-oracles
      { oracle: oracle }
      {
        stake-amount: ORACLE_STAKE_REQUIRED,
        reputation-score: u100,
        total-submissions: u0,
        correct-submissions: u0,
        registration-time: block-height,
        is-active: true
      }
    )
    (var-set oracle-count (+ (var-get oracle-count) u1))
    (ok true)
  )
)

(define-public (submit-weather-data 
  (location { latitude: int, longitude: int })
  (temperature int)
  (rainfall uint)
  (humidity uint)
  (wind-speed uint)
  (pressure uint)
  (timestamp uint)
)
  (let (
    (oracle tx-sender)
    (oracle-info (unwrap! (map-get? authorized-oracles { oracle: oracle }) ERR_UNAUTHORIZED))
    (data-key { location: location, timestamp: timestamp })
    (existing-data (map-get? weather-data data-key))
  )
    (asserts! (get is-active oracle-info) ERR_UNAUTHORIZED)
    (asserts! (validate-location location) ERR_INVALID_LOCATION)
    (asserts! (is-data-fresh timestamp) ERR_DATA_TOO_OLD)
    (asserts! (and (>= temperature -5000) (<= temperature 5000)) ERR_INVALID_DATA) ;; -50 degrees C to 50 degrees C
    (asserts! (<= rainfall u50000) ERR_INVALID_DATA) ;; Max 500mm
    (asserts! (<= humidity u100) ERR_INVALID_DATA)
    (asserts! (<= wind-speed u50000) ERR_INVALID_DATA) ;; Max 500 km/h
    (asserts! (and (>= pressure u80000) (<= pressure u110000)) ERR_INVALID_DATA) ;; 800-1100 hPa
    
    ;; Store weather data
    (map-set weather-data
      data-key
      {
        temperature: temperature,
        rainfall: rainfall,
        humidity: humidity,
        wind-speed: wind-speed,
        pressure: pressure,
        submitter: oracle,
        submission-time: block-height,
        validated: false
      }
    )
    
    ;; Update oracle stats
    (map-set authorized-oracles
      { oracle: oracle }
      (merge oracle-info { total-submissions: (+ (get total-submissions oracle-info) u1) })
    )
    
    ;; Update location history
    (let (
      (history (default-to 
        { last-update: u0, total-records: u0, average-temperature: 0, total-rainfall: u0 }
        (map-get? location-history { location: location })
      ))
      (new-record-count (+ (get total-records history) u1))
      (new-avg-temp (/ (+ (* (get average-temperature history) (to-int (get total-records history))) temperature) (to-int new-record-count)))
    )
      (map-set location-history
        { location: location }
        {
          last-update: block-height,
          total-records: new-record-count,
          average-temperature: new-avg-temp,
          total-rainfall: (+ (get total-rainfall history) rainfall)
        }
      )
    )
    
    (var-set data-submission-count (+ (var-get data-submission-count) u1))
    (ok true)
  )
)

(define-public (validate-weather-data 
  (location { latitude: int, longitude: int })
  (timestamp uint)
  (is-valid bool)
)
  (let (
    (oracle tx-sender)
    (oracle-info (unwrap! (map-get? authorized-oracles { oracle: oracle }) ERR_UNAUTHORIZED))
    (data-key { location: location, timestamp: timestamp })
    (weather-record (unwrap! (map-get? weather-data data-key) ERR_DATA_NOT_FOUND))
  )
    (asserts! (get is-active oracle-info) ERR_UNAUTHORIZED)
    (asserts! (not (is-eq oracle (get submitter weather-record))) ERR_UNAUTHORIZED)
    
    ;; Update validation status
    (map-set weather-data
      data-key
      (merge weather-record { validated: is-valid })
    )
    
    ;; Update oracle reputation if validation is positive
    (if is-valid
      (map-set authorized-oracles
        { oracle: (get submitter weather-record) }
        (merge 
          (unwrap-panic (map-get? authorized-oracles { oracle: (get submitter weather-record) }))
          { correct-submissions: (+ (get correct-submissions 
            (unwrap-panic (map-get? authorized-oracles { oracle: (get submitter weather-record) }))) u1) }
        )
      )
      true
    )
    
    (ok is-valid)
  )
)

(define-public (deactivate-oracle (oracle principal))
  (let (
    (caller tx-sender)
    (oracle-info (unwrap! (map-get? authorized-oracles { oracle: oracle }) ERR_UNAUTHORIZED))
  )
    (asserts! (is-eq caller (var-get contract-owner)) ERR_UNAUTHORIZED)
    (map-set authorized-oracles
      { oracle: oracle }
      (merge oracle-info { is-active: false })
    )
    (ok true)
  )
)

(define-public (withdraw-stake)
  (let (
    (oracle tx-sender)
    (stake-info (unwrap! (map-get? oracle-stakes { oracle: oracle }) ERR_UNAUTHORIZED))
    (oracle-info (unwrap! (map-get? authorized-oracles { oracle: oracle }) ERR_UNAUTHORIZED))
  )
    (asserts! (not (get is-active oracle-info)) ERR_UNAUTHORIZED)
    (asserts! (<= (get locked-until stake-info) block-height) ERR_UNAUTHORIZED)
    
    (try! (as-contract (stx-transfer? (get amount stake-info) tx-sender oracle)))
    (map-delete oracle-stakes { oracle: oracle })
    (map-delete authorized-oracles { oracle: oracle })
    
    (ok (get amount stake-info))
  )
)

(define-public (update-contract-owner (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_UNAUTHORIZED)
    (var-set contract-owner new-owner)
    (ok true)
  )
)

;; Administrative functions

(define-public (emergency-pause-oracle (oracle principal))
  (let (
    (caller tx-sender)
    (oracle-info (unwrap! (map-get? authorized-oracles { oracle: oracle }) ERR_UNAUTHORIZED))
  )
    (asserts! (is-eq caller (var-get contract-owner)) ERR_UNAUTHORIZED)
    (map-set authorized-oracles
      { oracle: oracle }
      (merge oracle-info { is-active: false })
    )
    (ok true)
  )
)

;; Initialize contract
(begin
  (var-set contract-owner tx-sender)
)


;; title: weather-oracle
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

