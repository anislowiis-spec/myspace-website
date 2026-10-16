# MySpace website

Shop the world, delivered to Iraq. Landing page in English, Arabic and Sorani Kurdish,
with customer accounts, a shipping-price calculator and shipment tracking.

| Folder | What it is |
|---|---|
| `website/` | The website itself (one page: `index.html`, plus logo and images). Published to GitHub Pages (www.myspaceapp.com) automatically on every push to `main`. |
| `supabase/migrations/` | Database: the `customers` table and the rule that creates a customer row (with a MySpace ID) at sign-up. |
| `supabase/functions/track/` | Tracking service for logged-in customers. Its API settings are stored as Supabase secrets. |
| `.github/workflows/deploy.yml` | Publishes `website/` to GitHub Pages. |

## Settings

Everything you may want to change is in the `SETTINGS` block near the top of the
script in `website/index.html` (email for notifications, phone, WhatsApp, Supabase
project, fuel surcharge percentage).

## See your customers

Supabase dashboard → **Table Editor → customers** (or **Authentication → Users**).
