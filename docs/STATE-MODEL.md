# Visual state model

- **Device Trust**: a mutually authenticated phone↔workstation session exists.
- **Owner Presence**: the phone reports unlocked user presence.
- **Authority**: sensitive owner actions are eligible only when Device Trust and Owner Presence are both active and policy permits the action.
- **Transport**: ADB/USB transport and reverse tunnel are currently available.

A locked phone should therefore show `Device Trust: ACTIVE`, `Owner Presence: LOCKED`, `Authority: SUSPENDED`.
