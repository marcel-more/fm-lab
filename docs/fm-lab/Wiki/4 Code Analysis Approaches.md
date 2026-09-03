FM-Lab provides 4 different approaches for analysis of your FileMaker solution. Each has a distinct focus and solves different purposes. They are interconnected by design to allow for an easy change of perspectives while digging into the solution at hand.

1. [Interactive exploration](#1-interactive-exploration)
2. [Static code analysis](#2-static-code-analysis)
3. [Graph analysis](#3-graph-analysis)
4. [Agentic analysis and code generation](#4-agentic-analysis-and-code-generation)

---

## 1. Interactive exploration

Start where you have a question and follow the answers. The web frontend turns the object catalog into a browsable structure: search across every object type in every file, open a detail view for a script, field, layout or custom function, and step through its references — what it uses, and where it is used itself. Every reference is a link, so a lookup that begins with a single field name can end three files away without you ever writing a query or opening FileMaker.

**Benefits:** No query language required and no prior knowledge of the solution's architecture. References are resolved at import time, so where-used answers are instant instead of assembled from text searches. And because it works on an exported catalog, you can explore a production solution without touching it — or opening it at all.

---

### 2. Static code analysis

Instead of asking questions one at a time, let a rule set ask them all at once. FM-Lab ships a library of analysis rules that run over the whole catalog and surface the patterns you would otherwise only find by accident: dead scripts, unused fields and layouts, unreferenced value lists, broken or dangling references, unexpected cross-file dependencies. Results are presented as dashboards, and every finding links back into the interactive views.

**Benefits:** Coverage is exhaustive and repeatable — the same rules find the same issues on every re-import, so you can track whether the solution is getting cleaner or messier over time. It scales to solutions nobody has a full mental model of any more, and it is the fastest way to size a cleanup or a migration before committing to it.

The rule library is extensible: any question you can express in SQL can become a permanent dashboard. A prepared agent skill helps you build a new dashboard by describing its goals in plain language.

---

### 3. Graph analysis

A FileMaker solution is a network — scripts calling scripts, layouts touching fields, table occurrences pulling in relationships. Graph analysis takes that network seriously: FM-Lab builds the dependency graph from the resolved references and segments it into communities using clustering algorithms, then names the resulting modules semantically (with the help of an LLM). The **Graph Explorer** and the **Atlas** let you look at the solution from above — module by module, edge by edge — and zoom in from a bird's-eye treemap down to a single object.

Extensive filter options and overlay information help you drill down into the nodes and their meaning. On-the-fly result lists and search filters allow for a specific handover into the interactive exploration mode.

Complementary to the neighborhood view, the Explorer's **trace mode** follows a single flow instead of every edge: the call chain up and down from a start script or layout, the objects those scripts actually touch, and the script triggers of layouts the flow enters. The result is a much smaller, denser graph that answers "what does this process touch?" rather than "what is nearby?".

Agents benefit from the same pre-computed clusters: they can read the underlying architecture and overlay it with semantic signals to explain the solution's business goals.

**Benefits:** It reveals the architecture that was never documented: which parts of the solution actually belong together, where the real coupling is, and which modules could be extracted or replaced independently. Cluster boundaries are derived from measured dependencies, not from naming conventions or folder structure — so they show how the solution behaves, not how someone once intended it to be organized. This is the perspective you need for refactoring decisions, module ownership, and understanding the blast radius of a change.

---

### 4. Agentic analysis and code generation

The catalog is not only a UI backend — it is a knowledge base an AI agent can query directly. Ask a question in plain language and the agent picks the right tables, builds the SQL, runs it and explains the result. It goes beyond structure: it reads call chains, variable naming, layout labels and comments to describe what a script is actually _for_ in business terms, not just what it does technically. The same grounding drives code generation — new FileMaker scripts, custom functions and schema are generated against real object IDs from your solution, validated against the function and script-step reference, and delivered as paste-ready snippets.

**Benefits:** No sophisticated prompts, no RAG, no token intense grepping through walls of text , no fixed set of pre-built reports — questions that no dashboard anticipated get answered anyway. The agent builds its own queries on demand and gets answers straight from your solution's knowledge graph, codified as a generic object model. This speeds up results and saves you tokens. The agent can ask directed questions against your solution at any level of detail and gets instant results.

Because every answer and every generated artifact is grounded in the actual catalog rather than the model's memory, references are real and verifiable, and generated code passes a validation gate before it ever reaches your clipboard. It is the difference between an assistant that guesses about your solution and one that has read all of it on demand.

If you want to see it with your own eyes instead of relying on the agent's conclusions, just ask it to show you: one skill jumps straight to the object in the interactive exploration views, another opens it in the FileMaker solution itself (via the fmIDE 'Name that Thing' API).
