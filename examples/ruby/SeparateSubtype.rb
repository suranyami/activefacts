require 'activefacts/api'

module OneToOnes

  class ClaimID < AutoCounter
    value_type 
  end

  class DriverName < String
    value_type 
  end

  class Claim
    identified_by :claim_id
    one_to_one :claim_id, ClaimID               # See ClaimID.claim_by_claim_id
  end

  class Driver
    identified_by :driver_name
    one_to_one :driver_name                     # See DriverName.driver
  end

  class Incident
    identified_by :claim
    one_to_one :claim                           # See Claim.incident
  end

  class VehicleIncident < Incident
    has_one :driver                             # See Driver.all_vehicle_incident
  end

end