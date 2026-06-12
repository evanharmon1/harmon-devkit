# Web Templates

HTML/web snippets.

| Template | Description |
| --- | --- |
| [`netlifyForm.html`](./netlifyForm.html) | Contact form wired for [Netlify Forms](https://docs.netlify.com/forms/setup/) (`data-netlify="true"`) with a hidden honeypot field for spam protection and basic client-side validation (required fields, email/phone patterns) |

## Usage

Drop the form into a page deployed on Netlify — Netlify detects the `data-netlify` attribute at build time and handles submissions. Adjust fields and the `name="contact"` form name to suit; keep the hidden `form-name` input in sync with it.
