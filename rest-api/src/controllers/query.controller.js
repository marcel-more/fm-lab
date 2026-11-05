const templateService = require('../services/template.service');
const formatters = require('../formatters');
const { sendFormatted } = require('../utils/response-builder');

/**
 * Query Controller
 * Handles requests for template-based endpoints (/query, /report)
 */

/**
 * GET/POST /api/query - Execute a query template
 * Every query area except system (query-discovery), then bundle queries
 */
async function executeQuery(req, res, next) {
  try {
    // Support both GET and POST
    const { template, params, format = 'json', meta, debug, theme, direction, title, ...otherParams } = {
      ...req.query,
      ...req.body,
    };

    // Reserved parameters that should not be treated as template parameters
    const reservedParams = ['template', 'params', 'format', 'meta', 'debug'];

    // Extract template parameters from query/body (all non-reserved params)
    const directParams = {};
    for (const [key, value] of Object.entries(otherParams)) {
      if (!reservedParams.includes(key)) {
        directParams[key] = value;
      }
    }

    // Parse params if it's a string (from GET request)
    let parsedParams = params;
    if (typeof params === 'string') {
      try {
        parsedParams = JSON.parse(params);
      } catch (error) {
        return next({
          code: 'VALIDATION_ERROR',
          message: 'Invalid JSON in params parameter',
          statusCode: 400,
        });
      }
    }

    // Merge direct params with parsed params (parsed params take precedence)
    const finalParams = {
      ...directParams,
      ...(parsedParams || {}),
    };

    // Execute template
    const result = await templateService.executeTemplate(
      req.solutionContext,
      template,
      finalParams,
      'query' // query areas
    );

    // For content templates, always use content formatter (except for json)
    // Content is already pre-formatted, so other formatters would add unwanted structure
    let effectiveFormat = format;
    if (result.meta.template_type === 'content' && format !== 'json') {
      effectiveFormat = 'content';
    }

    // Build formatter options (for Mermaid and other formatters that support options)
    const formatterOptions = {
      theme: theme || 'default',
      direction: direction || result.meta.template_metadata?.mermaid_direction || 'TD',
      title: title || result.meta.template_description || 'FileMaker Diagram',
      meta: {
        template_description: result.meta.template_description,
        mermaid_direction: result.meta.template_metadata?.mermaid_direction,
      },
    };

    // Format data (with options)
    const formattedData = formatters.format(result.data, effectiveFormat, formatterOptions);

    // Special handling for Mermaid formats (direct output without JSON wrapper)
    if (format === 'mermaid' || format === 'mermaid-raw') {
      const contentType = format === 'mermaid'
        ? 'text/html; charset=utf-8'
        : 'text/plain; charset=utf-8';

      res.setHeader('Content-Type', contentType);
      res.send(formattedData);
      return;
    }

    // Send formatted response for other formats
    sendFormatted(
      res,
      formattedData,
      effectiveFormat,
      meta ? result.meta : null,
      debug ? result.sql : null
    );
  } catch (error) {
    next(error);
  }
}

/**
 * GET/POST /api/report - Execute report template
 * Internal templates of the system area (templates/queries/system/)
 */
async function executeReport(req, res, next) {
  try {
    // Support both GET and POST
    const { template, params, format = 'html', meta, debug, theme, direction, title, ...otherParams } = {
      ...req.query,
      ...req.body,
    };

    // Reserved parameters that should not be treated as template parameters
    const reservedParams = ['template', 'params', 'format', 'meta', 'debug'];

    // Extract template parameters from query/body (all non-reserved params)
    const directParams = {};
    for (const [key, value] of Object.entries(otherParams)) {
      if (!reservedParams.includes(key)) {
        directParams[key] = value;
      }
    }

    // Parse params if it's a string (from GET request)
    let parsedParams = params;
    if (typeof params === 'string') {
      try {
        parsedParams = JSON.parse(params);
      } catch (error) {
        return next({
          code: 'VALIDATION_ERROR',
          message: 'Invalid JSON in params parameter',
          statusCode: 400,
        });
      }
    }

    // Merge direct params with parsed params (parsed params take precedence)
    const finalParams = {
      ...directParams,
      ...(parsedParams || {}),
    };

    // Execute template
    const result = await templateService.executeTemplate(
      req.solutionContext,
      template,
      finalParams,
      'report' // system area
    );

    // For content templates, always use content formatter (except for json)
    // Content is already pre-formatted, so other formatters would add unwanted structure
    let effectiveFormat = format;
    if (result.meta.template_type === 'content' && format !== 'json') {
      effectiveFormat = 'content';
    }

    // Build formatter options (for Mermaid and other formatters that support options)
    const formatterOptions = {
      theme: theme || 'default',
      direction: direction || result.meta.template_metadata?.mermaid_direction || 'TD',
      title: title || result.meta.template_description || 'FileMaker Report',
      meta: {
        template_description: result.meta.template_description,
        mermaid_direction: result.meta.template_metadata?.mermaid_direction,
      },
    };

    // Format data (with options)
    const formattedData = formatters.format(result.data, effectiveFormat, formatterOptions);

    // Special handling for Mermaid formats (direct output without JSON wrapper)
    if (format === 'mermaid' || format === 'mermaid-raw') {
      const contentType = format === 'mermaid'
        ? 'text/html; charset=utf-8'
        : 'text/plain; charset=utf-8';

      res.setHeader('Content-Type', contentType);
      res.send(formattedData);
      return;
    }

    // Send formatted response for other formats
    sendFormatted(
      res,
      formattedData,
      effectiveFormat,
      meta ? result.meta : null,
      debug ? result.sql : null
    );
  } catch (error) {
    next(error);
  }
}

/**
 * GET /api/query/list - List the queries of the content areas (builtin, custom, community)
 */
async function listQueryTemplates(req, res, next) {
  try {
    const templates = await templateService.listTemplates('query');

    res.json({
      success: true,
      data: templates,
      meta: {
        count: templates.length,
        source: 'custom',
      },
    });
  } catch (error) {
    next(error);
  }
}

/**
 * GET /api/report/list - List the internal templates of the system area
 */
async function listReportTemplates(req, res, next) {
  try {
    const templates = await templateService.listTemplates('report');

    res.json({
      success: true,
      data: templates,
      meta: {
        count: templates.length,
        source: 'standard',
      },
    });
  } catch (error) {
    next(error);
  }
}

module.exports = {
  executeQuery,
  executeReport,
  listQueryTemplates,
  listReportTemplates,
};
