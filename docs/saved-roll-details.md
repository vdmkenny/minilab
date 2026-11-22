# Saved cameras, lenses and copyright names

In **New roll**, Camera, Lens and Copyright are editable fields with a drop-down
arrow. Type a new value or use the arrow to search and select a saved entry.
Creating the roll remembers its values. The same controls are available when
editing a roll's metadata in Export.

Existing values from rolls in the current library are added automatically.
Suggestions belong to that library and are kept in its `roll-details.json`.
They travel with it when the library is moved or copied. Blank values are
ignored, and spaces around a suggestion are trimmed.

Choose **Saved entries...** below Copyright, or **Manage saved entries...** in
any of the drop-downs, to open the manager. Select Cameras, Lenses or Copyright
names. You can search the list, remove individual entries, or type a new entry
and save it without making a roll.

Removing a suggestion keeps existing rolls' metadata. It stays hidden when old
rolls are read again, including after restarting the app. Explicitly using that
value for a new roll, editing a roll to use it, or adding it in the manager
restores the suggestion. Emptying a roll's field does not delete its saved entry;
use the manager for that.

Saved entries are written separately from roll metadata. If updating them fails,
the app reports the failure and keeps the roll that was created or edited. An
unreadable suggestions file is left intact, so a failed read cannot replace it
with an empty list.
