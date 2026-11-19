# DocumentToolScaffold

DocumentToolScaffold is a HAVEN tool scaffold for reading documents natively. It reads docx, pdf, md, rtf and txt
into one common paragraph format, numbers the paragraphs stably across versions (A1, A2, A117a …) and prepares
deterministic, model-ready text. Other scaffolds use it so that no model tokens are spent on reading documents.

Owner: the **Digipomps** group identity (Stiftelsen Digipomps, org. no. 922 135 134), with Kjetil and Vegar as group
owner members. Changes are made by members of the Digipomps organisation on GitHub; others are welcome
to open issues and pull requests.

## Purposes

What the scaffold is for, as purposes. The same list is in code (`DocumentToolPurposes`), and the cell
`cell:///DocumentTools` returns it over CellProtocol (`ExploreManifest.intent.purposeRefs` and the `purposes` key
path), so other scaffolds can ask what DocumentToolScaffold can do. A test checks that this README and the code list the
same purposes.

*available* = implemented and tested in the library today. *planned* = agreed, not built yet. *parked* = deferred.

| Code | Purpose | Title | Goal | Status |
|---|---|---|---|---|
| root | `purpose://candidate.dokumentverktoy.root` | Read, number and prepare documents once, natively, for every scaffold | A scaffold that has a document gets numbered, structured text without writing its own reader and without spending model tokens on reading it. | available |
| A | `purpose://candidate.dokumentverktoy.read` | Read five formats into one common format | docx, pdf, md, rtf and txt give the same structure: paragraphs with style, text and footnotes, plus format, warnings and source hash. | available |
| A1 | `purpose://candidate.dokumentverktoy.read.docx` | Word documents | Paragraphs, style names and footnotes, unchanged from the argument map reader. | available |
| A2 | `purpose://candidate.dokumentverktoy.read.markdown` | Markdown | Headings, lists, quotes and code blocks get their own style; [^1] footnotes are collected. | available |
| A3 | `purpose://candidate.dokumentverktoy.read.plaintext` | Plain text | Paragraphs split on blank lines; UTF-8, UTF-16 with BOM and Windows-1252 are recognised. | available |
| A4 | `purpose://candidate.dokumentverktoy.read.rtf` | RTF | Own reader: paragraphs, \u and \'hh characters, heading styles from the stylesheet, footnotes. | available |
| A5 | `purpose://candidate.dokumentverktoy.read.pdf` | PDF with a text layer | poppler pdftotext plus our own paragraph layer: at least 90 % exact paragraphs on the reference PDFs. A scanned PDF gives no-text-layer, not empty text. | available |
| A6 | `purpose://candidate.dokumentverktoy.read.safe-input` | Hostile files stop safely | Format is decided by content, not file name; size limit; no network; XML without external entities; every error has a code. | available |
| B | `purpose://candidate.dokumentverktoy.number` | Number paragraphs stably across versions | A-numbers, letter suffixes for new paragraphs, numbers never reused, and a change outcome against the previous version. The prefix can be set. | available |
| B1 | `purpose://candidate.dokumentverktoy.number.version-diff` | Version diff between drafts | Changed, moved, new, removed and merged paragraphs with similarity, as its own result. | available |
| C | `purpose://candidate.dokumentverktoy.model-ready` | Finished text for a model | One deterministic text ([A12] (Heading 2) …, footnotes under the paragraph) with a hash. | available |
| C1 | `purpose://candidate.dokumentverktoy.model-ready.chunks` | Chunks for the model window | Split on paragraph boundaries within a token budget; a paragraph is never split; each chunk lists its A-numbers. | available |
| C2 | `purpose://candidate.dokumentverktoy.model-ready.token-estimate` | Token estimate before a run | Estimate per document and per chunk, labelled as an estimate with its method. | available |
| C3 | `purpose://candidate.dokumentverktoy.model-ready.refs-check` | The model's A-numbers exist | Every A-number in a model answer must exist in the text the model was given. | available |
| D | `purpose://candidate.dokumentverktoy.reach` | Other scaffolds can use it | A Swift library for use in the same process, and a cell for use over CellBridge. | available |
| D1 | `purpose://candidate.dokumentverktoy.reach.library` | Library without cells | DocumentTools depends only on Foundation, FoundationXML and ZIPFoundation, and builds on macOS and Linux. | available |
| D2 | `purpose://candidate.dokumentverktoy.reach.cell` | Cell with key paths | cell:///DocumentTools with read, number, prepare and diff; data in the payload, no file on disk. | available |
| D3 | `purpose://candidate.dokumentverktoy.reach.announced` | Purposes are readable and queryable | This list is in the README and in code, and the cell answers it over CellProtocol (ExploreManifest purposeRefs and the purposes key path). | available |
| D4 | `purpose://candidate.dokumentverktoy.reach.argumentmap-uses-it` | The argument map uses the tool | ArgumentMapCell imports DocumentTools with no changed behaviour. | planned |
| D5 | `purpose://candidate.dokumentverktoy.reach.admin-entry` | AdminScaffold is the way into the rest of HAVEN | The scaffold is configured with the AdminScaffold endpoint, registers there with owner, purposes and instance identity, and finds other scaffolds and purposes through it. | planned |
| E | `purpose://candidate.dokumentverktoy.paid` | Paid use with micropayments | Deferred to a separate PDD. | parked |
| F | `purpose://candidate.dokumentverktoy.operations` | Operations are visible to AdminScaffold | The scaffold emits operational events as a Flow, and AdminScaffold subscribes to it. | planned |
| F1 | `purpose://candidate.dokumentverktoy.operations.events` | Operational events without content | Start, stop, read completed, read failed (error code), pdf-engine-missing, timeout and health. Format, size, duration and error code only; never document text, file names or source hashes. | available |
| F2 | `purpose://candidate.dokumentverktoy.operations.admin-subscribes` | AdminScaffold subscribes | AdminScaffold attaches to the flow with an admin.observer proof; without a proof the subscription is refused. | planned |
| G | `purpose://candidate.dokumentverktoy.ownership` | Digipomps owns the scaffold | The owner is the Digipomps group identity (Stiftelsen Digipomps, org. no. 922 135 134), with Kjetil and Vegar as group owner members, declared in a signed service description that AdminScaffold reads. | planned |

## AdminScaffold

AdminScaffold (in CellScaffold) is DocumentToolScaffold's way into the rest of HAVEN (purpose D5). The scaffold is
configured with the AdminScaffold endpoint, registers there with owner, purposes and instance identity, and finds other
scaffolds and purposes through it. AdminScaffold subscribes to the scaffold's flow of operational events (purpose F).
The events carry format, size, duration and error codes, never document content. The events are emitted by the cell today.

| Setting | What it does |
|---|---|
| `DOCUMENTTOOLS_ADMIN_ENDPOINT` | AdminScaffold's services cell. The scaffold sends its signed service description there (`scaffoldServices.register`). Without it, health says `admin-endpoint-missing`. |
| `DOCUMENTTOOLS_ADMIN_ROLE_ENDPOINT` | Where an `admin.observer` credential is checked. Defaults to `AdminRoleEnrollment` next to the admin endpoint. |
| `DOCUMENTTOOLS_INSTANCE_ID` | The instance name in the service description. Defaults to a new UUID per start. |

Besides the owner, only an identity whose `admin.observer` credential AdminScaffold verifies may read the flow and the
`documenttools.*` get keys. It is asked on every request, so a revoked credential stops working at once, and this never
gives write access. The receiving side in AdminScaffold is not built yet.

## Using the library

```swift
.package(url: "https://github.com/Digipomps/DocumentToolScaffold.git", from: "0.1.0"),
// target dependency: .product(name: "DocumentTools", package: "DocumentToolScaffold")
```

```swift
import DocumentTools

let document = try DocumentIntake.read(data: data, name: "draft.docx")       // format from content, not name
let numbered = ParagraphNumbering.number(document.paragraphs, previous: lastVersion?.paragraphs)
let prepared = ModelReadyText.prepare(numbered.paragraphs, maxTokensPerChunk: 8_000)
// prepared.text:   "[A12] (Heading 2) …"  plus  "  [A12 fotnote 1] …"
// prepared.sha256, prepared.tokenEstimate (an estimate, labelled with its method), prepared.chunks
let check = ModelReadyText.verifyRefs(["A12", "A999"], knownRefs: numbered.paragraphs.map(\.ref))
```

Errors are `DocumentToolsError` with a stable `code` (`too-large`, `unknown-format`, `empty-document`,
`unreadable-rtf`, `pdf-engine-missing`, `pdf-timeout`, `unreadable-pdf`, `no-text-layer`, …).

## Using the cell

The product `DocumentToolCells` has `DocumentToolsCell`, a CellProtocol cell for use over CellBridge. It stores nothing;
the caller keeps the previous version and sends it back for numbering.

| Key path | Method | Input → output |
|---|---|---|
| `documenttools.read` | set | `{name, dataBase64}` → `DocumentText` |
| `documenttools.number` | set | `{paragraphs, previous?, prefix?}` → numbering outcome |
| `documenttools.diff` | set | `{numbered}` → version diff |
| `documenttools.prepare` | set | `{numbered, maxTokensPerChunk?}` → model-ready text |
| `documenttools.verifyRefs` | set | `{refs, knownRefs}` → `{ok, unknown}` |
| `documenttools.purposes` | get | the purposes above |
| `documenttools.ownership` | get | owner group and group owner members |
| `documenttools.state` | get | health, for example whether the PDF engine is present |

Errors come back as `{ "error": { "code", "message" } }`. `ExploreManifest.intent.purposeRefs` for the cell carries the
purpose references, so a scaffold can find out what the cell is for without calling it. Operational events
(`DocumentToolOpsEvent`) go out on the cell's flow with the topic `documenttools.ops.v1`.

CellProtocol is pinned to the same revision as CellScaffold. CellProtocol depends on the private package
`Digipomps/FileUtils-c`, so building `DocumentToolCells` needs access to it; the `DocumentTools` library does not.

## Dependencies

- Foundation, FoundationXML and [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) (MIT).
- PDF only: `pdftotext` from poppler-utils at run time (GPL, called as a separate process, not linked). Without it the PDF
  reader answers `pdf-engine-missing`. Set `DOCUMENTTOOLS_PDFTOTEXT` to use another path.

## Building and testing

Builds and tests run locally, not in GitHub Actions:

```sh
swift build --build-tests
swift test
```

On Linux the PDF tests also compare with a reference measurement made with poppler 24.02 (Ubuntu noble). Tests that need
a private manuscript run only when `DOCUMENTTOOLS_GOLDEN_DIR` points to it; that text is never in this repository.

## License

Apache-2.0. See [LICENSE](LICENSE).
