# Contributing to Hibiscus

Thank you for considering a contribution to Hibiscus. Contributions are welcome, but Hibiscus is a focused independent project with a defined product and design direction. Opening a pull request does not guarantee that it will be accepted or merged.

## Before you start

You may generally open a pull request directly for:

- bug fixes and stability improvements;
- performance improvements;
- tests, documentation, and tooling or build-system work;
- focused internal changes that do not alter the visible product experience.

Please open a GitHub Issue and receive maintainer agreement before substantial implementation if it involves:

- a new feature or removal of an existing feature;
- UI or interaction design changes;
- significant changes to product behavior, scope, or workflow.

An Issue helps confirm that the proposed work fits Hibiscus before substantial implementation begins.

## Making changes

- Keep each contribution focused on one problem. Avoid unrelated refactors, rewrites, formatting changes, or dependency additions.
- Reuse the existing Camera, Grade, rendering, import, and export architecture where appropriate.
- Preserve Hibiscus's supported iOS versions and focused Camera + Grade product model unless an approved Issue says otherwise.
- Add or update tests and documentation when they are relevant to the change.

## Testing

Test changes that affect the app before submitting them. Include the devices, iOS versions, and checks you performed in the pull-request description, along with any limitations.

Camera, capture, Live Photo, flash, lens, RAW, export, rendering, performance, and other hardware-dependent changes should be tested on a physical iPhone whenever reasonably possible. Simulator-only validation is not sufficient evidence for hardware behavior.

At minimum, confirm that the `Hibiscus` scheme builds in Xcode. For a command-line build without code signing, see the [Build section in the README](README.md#build).

## Pull requests

A useful pull request includes:

- a clear summary of the problem and solution;
- a linked Issue when prior approval is required;
- testing details and relevant screenshots for visible changes;
- known limitations, follow-up work, or hardware that was not available for testing.

A change can be technically correct and still fall outside Hibiscus's product direction, design, scope, or maintenance goals. Reviews may request revisions, and not every contribution will be merged.

## License and branding

Contributions to the covered Hibiscus source code are made under the [Mozilla Public License 2.0](LICENSE). By submitting a contribution, you confirm that you have the right to provide it under that license.

Please also follow the repository's existing [brand and redistribution rules](README.md#brand-and-marketing-assets). The Hibiscus name, app icon, visual identity, screenshots, and other brand or marketing assets are not licensed under the MPL-2.0 unless explicitly stated otherwise. Forks and redistributed builds should use their own name, icon, and branding.
