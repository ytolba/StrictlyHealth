# Ring compatibility

This is experimental, independently implemented Bluetooth software. Selecting a
model does not change your firmware or make unsupported measurements appear.

| Ring | Direct Bluetooth in this fork | Account export / Apple Health |
| --- | --- | --- |
| First generation | Not validated; disabled | Import dated export fields or read available HealthKit data |
| Gen 2 | Not validated; disabled | Import dated export fields or read available HealthKit data |
| Gen 3 Heritage / Horizon | A Gen 3 Horizon authenticated and synced on a user's device | Available when the source contains those records |
| Ring 4 / Ceramic | Shared protocol path; untested in this fork | Available when the source contains those records |
| Ring 5 | Upstream reports live sync; untested in this fork | Available when the source contains those records |
| Unknown / future models | Existing-key sync experimental; new pairing disabled | Import/HealthKit does not require a live connection |

Only Gen 3 Horizon authentication and sync have been confirmed in this app.
Battery response, complete-night stages, enabling standard measurements, and every
firmware variant still require physical-device checks. Do not advertise universal
Bluetooth compatibility or medical accuracy.

The BLE adapter discovers the proprietary Oura service and subscribes to all
supported notify/indicate characteristics. It excludes the Ring 5 charging-case
service. Firmware-specific history fallback is implemented by the vendored client.
Appearance, ring size, color and model-selection labels are not protocol evidence.

## Pairing safely

Use your existing key when available. A ring does not reveal its pairing key, and
an arbitrary new key cannot authenticate an already-onboarded ring. The app saves
its candidate key before attempting new pairing, and refuses pairing if secure
storage cannot be verified. It does not factory-reset the ring from the dashboard.

Do not reset a ring just to troubleshoot a timeout. A factory reset erases unsynced
on-ring history and changes the onboarding state. Export and back up data first.
Keep other nearby rings away during first pairing; never pair someone else's ring.
One active ring/key per app installation is supported. Multiple people's accounts
and automatic switching among multiple rings are not implemented.

## What a compatibility report should include

Model/generation, firmware, iOS/app versions, whether authentication succeeded,
whether battery responded, whether records were saved, and whether a complete
night has actual stages. Report each capability separately. Never attach keys,
full health archives, unredacted device identifiers, or phone backups to an issue.

Upstream technical evidence: https://github.com/Th0rgal/open_oura
Official ring catalogue: https://ouraring.com/store
