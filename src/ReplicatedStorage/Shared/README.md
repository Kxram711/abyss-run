# Shared modules

Code here lives in `ReplicatedStorage` and is visible to both the server and
clients: shared types, enums, config constants (e.g. Lumen tuning values from
GDD §4.2), and cross-service contracts. Gameplay delegations add modules here
as needed; the scaffold ships this as an empty seam.
