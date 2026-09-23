# Architecture

- [Core](#core)
- [DuckDB-powered Object Catalog](#duckdb-powered-object-catalog)
- [Interface](#interface)
- [Deployment options](#deployment-options)
- [Different use cases](#different-use-cases)

The FM-Lab architecture separates the **[ingestion pipeline](How%20it%20works.md#ingestion-pipeline)** from the **[interaction layer](How%20it%20works.md#interaction-layer)** and defines the infrastructure components between them.

The ingestion pipeline converts FileMaker SaXML exports into a [DuckDB-powered Object Catalog](#duckdb-powered-object-catalog). The interaction layer then consumes this catalog through the REST API, a web interface built on top of that API, or direct agentic tool access.

FM-Lab relies on an open-source tech stack that can run on different operating systems and in flexible deployment configurations.

![FM-Lab-flexible-Architecture.jpg](../Assets/FM-Lab-flexible-Architecture.jpg)

---

### Core

The core component is the **Object Catalog**. It is exposed through a **REST API** to separate the source of truth from the consuming tools:
- [user interface](#filemaker-analysis-app)
- [AI agents](#agentic-analytics-and-coding-workflow)
- [other tools](#object-catalog-server)

---

### DuckDB-powered Object Catalog

Choosing DuckDB as the core engine is a major design decision in this architecture. It integrates cleanly into the FM-Lab tech stack and provides several major benefits:

- XML parsing capabilities that combine XPath extraction with SQL-based transformation logic
- powerful structured queries (like [CTEs](https://duckdb.org/docs/current/sql/query_syntax/with), [Window Functions](https://duckdb.org/docs/lts/sql/functions/window_functions), [nested structures](https://duckdb.org/docs/lts/sql/functions/nested), [JSON](https://duckdb.org/docs/lts/data/json/json_functions), [RegExp](https://duckdb.org/docs/lts/sql/functions/regular_expressions), [Wildcards](https://duckdb.org/docs/lts/sql/functions/pattern_matching), flexible [UNION](https://duckdb.org/docs/lts/sql/query_syntax/setops) statements)
- analytical storage format
- RAM-accelerated, in-process execution without client-server overhead
- scalability far beyond other options (suitable for [terabyte-sized](https://duckdb.org/docs/lts/guides/performance/working_with_huge_databases) analytical workloads)
- very flexible [deployment options](https://duckdb.org/docs/lts/clients/overview)

As an open-source infrastructure component, DuckDB is one of the building blocks that makes FM-Lab practical, portable and extensible. To be honest – without DuckDB, this project would never have happened.

Another advantage FM-Lab relies on is DuckDB's rich ecosystem of [community extensions](https://duckdb.org/community_extensions/list_of_extensions). The key enabler for XML parsing is the excellent [**webbed** extension](https://duckdb.org/community_extensions/extensions/webbed) that brings XPath-based data extraction to the SQL-engine.


---

### Interface

The [REST API](../rest-api/REST%20API%20Overview.md) supports:
- distinct endpoints for common tasks (based on a query library)
- paged responses (with offset, limit and sorting)
- different [output formats](../rest-api/REST%20API%20Output%20Formats.md) (JSON, text, HTML, raw data)
- status and health checks
- extensibility for plugins

To make this pattern more flexible, FM-Lab provides a dedicated endpoint for custom templates. These templates live in a separate directory and allow you to extend the predefined query library with project-specific queries.

A built-in frontend server based on React/Vite is provided as a convenient starting point for exploring your FileMaker solution data in the Object Catalog.


---

### Deployment options

By abstracting the Object Catalog behind a standard REST API, FM-Lab supports different deployment options.

The default deployment is a local Express server running on Node.js that exposes the API on `http://localhost:3003`. It serves a local DuckDB database file inside the project folder. The corresponding frontend server runs on `http://localhost:5173` and can be disabled if not needed.

For multi-user deployments, the Object Catalog can be served through the REST API from a separate server. The ingestion pipeline can run there as well or update the catalog from another environment. The team can then access it through a dedicated IP address or subdomain.

One possible scenario is an autonomous ingestion pipeline running alongside FileMaker Server. This could then be accessed by a team of multiple developers as a central Object Catalog.

Because DuckDB is lightweight and runs in many environments, additional deployment patterns are possible depending on your intended use case.


---

### Different use cases

#### FileMaker analysis app
You can use FM-Lab as a browser-based GUI tool for FileMaker analysis without connecting any LLM or agentic tools. Its core functionality includes the XML conversion process powered by DuckDB and shell scripts, plus the local infrastructure for the REST API and web interface. This is the simplest use case and works out of the box once the required dependencies are installed.

#### Agentic analytics and coding workflow
FM-Lab provides the Object Catalog together with prebuilt [Skills](../skills/Skills.md) and references as a solid foundation for your agents. A first-class experience depends on strong frontier models such as Claude or Codex. A good setup includes an IDE such as VS Code, Codium, Cursor, Windsurf or Antigravity, together with an agent plugin. That makes it easier to navigate the prepared folder structure of the project and gives you access to more features. Pure terminal mode is also possible.

#### Object Catalog server
If you only want to use the unified Object Catalog to support your own tool or workflow, you can ignore the extra features. Start the API server with the generated DuckDB database and connect your tool through the REST API endpoints. Refer to the [endpoint documentation](../rest-api/REST%20API%20Overview.md) and use Postman or your browser to explore possible URL patterns for your specific case.