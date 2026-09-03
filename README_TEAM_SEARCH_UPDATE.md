# Team search update

This update replaces the player team dropdown with a searchable picker.

Behaviour:
- On first entry, all active teams are suggested.
- Typing filters teams by the beginning of the team name (case/accent insensitive).
- A team can be selected by tapping a suggestion or with Arrow Up/Down + Enter.
- The association button stays disabled until a valid team is selected.
- Existing optional team PIN behaviour is unchanged.

To apply to an existing Step 6 project, overwrite:
- `src/pages/PlayerPage.tsx`
- `src/styles.css`

No Supabase migration is required.
