const dashboardService = require('./dashboard.service');
const testsService = require('./tests.service');
const { ID_PATTERN: TEST_ID_PATTERN } = require('./tests-schemas');
const { getDefaultFavoritesStore } = require('../config/favorites-store');
const { createError } = require('../middleware/error-handler');

/**
 * Favorites service — validation and availability on top of the favorites
 * store. Workspace-wide and solution-independent: nothing here reads a
 * solution context.
 *
 * Every favoritable kind has a resolver:
 *   dashboard  the bundle or single-file unit exists (404 otherwise) and lives
 *              in a content area (builtin, custom, community — 422 otherwise)
 *   test       the Analysis Test exists (404 otherwise); tests of every area
 *              are favoritable
 * An unknown kind is a 400. Listing splits the stored ids into `items`
 * (available favorites) and `missing` (ids that no longer resolve or are no
 * longer favoritable). Listing never cleans up — removing a missing id is the
 * user's decision.
 */

const KIND_DASHBOARD = 'dashboard';
const KIND_TEST = 'test';
const FAVORITE_KINDS = [KIND_DASHBOARD, KIND_TEST];

function isNotFound(err) {
  return err.code === 'TEMPLATE_NOT_FOUND' || err.code === 'VALIDATION_ERROR';
}

function createFavoritesService({ store, dashboards = dashboardService, tests = testsService } = {}) {
  if (!store) throw new Error('createFavoritesService: a store is required');

  const resolvers = {
    [KIND_DASHBOARD]: {
      /** Throws 400/404/422 when the id cannot be favorited. */
      async assertFavoritable(id) {
        const bundle = await dashboards.getBundle(id);
        if (!dashboards.isFavoritableArea(bundle.area)) {
          throw createError('NOT_FAVORITABLE', `Dashboard '${id}' cannot be favorited (area: ${bundle.area})`, {
            dashboardId: id,
            area: bundle.area,
          });
        }
      },
      isValidId: id => dashboards.isValidBundleId(id),
      label: 'dashboard',
    },
    [KIND_TEST]: {
      async assertFavoritable(id) {
        await tests.getTest(id);
      },
      isValidId: id => typeof id === 'string' && TEST_ID_PATTERN.test(id),
      label: 'test',
    },
  };

  function resolverFor(kind) {
    const resolver = Object.prototype.hasOwnProperty.call(resolvers, kind) ? resolvers[kind] : null;
    if (!resolver) {
      throw createError('VALIDATION_ERROR', `Unknown favorite kind: ${kind} (expected ${FAVORITE_KINDS.join(' | ')})`);
    }
    return resolver;
  }

  /** Whether a stored id still resolves to a favoritable object. */
  async function isAvailable(resolver, id) {
    try {
      await resolver.assertFavoritable(id);
      return true;
    } catch (err) {
      if (isNotFound(err) || err.code === 'NOT_FAVORITABLE') return false;
      throw err;
    }
  }

  async function split(resolver, entries) {
    const available = await Promise.all(entries.map(e => isAvailable(resolver, e.id)));
    return {
      items: entries.filter((_, i) => available[i]),
      missing: entries.filter((_, i) => !available[i]).map(e => e.id),
    };
  }

  /** → { items: [{ id, added_at }], missing: [id] } */
  async function list(kind) {
    const resolver = resolverFor(kind);
    return split(resolver, store.list(kind));
  }

  /** Idempotent add. 400 invalid kind/id · 404 unknown object · 422 not favoritable. */
  async function add(kind, id) {
    const resolver = resolverFor(kind);
    await resolver.assertFavoritable(id);
    return split(resolver, store.add(kind, id));
  }

  /**
   * Idempotent remove. Only the id pattern is checked — a favorite whose
   * object is gone must stay removable.
   */
  async function remove(kind, id) {
    const resolver = resolverFor(kind);
    if (!resolver.isValidId(id)) {
      throw createError('VALIDATION_ERROR', `Invalid ${resolver.label} id: ${id}`);
    }
    return split(resolver, store.remove(kind, id));
  }

  return {
    list,
    add,
    remove,
    listDashboards: () => list(KIND_DASHBOARD),
    addDashboard: id => add(KIND_DASHBOARD, id),
    removeDashboard: id => remove(KIND_DASHBOARD, id),
  };
}

let defaultService = null;
function service() {
  if (!defaultService) defaultService = createFavoritesService({ store: getDefaultFavoritesStore() });
  return defaultService;
}

module.exports = {
  FAVORITE_KINDS,
  createFavoritesService,
  list: kind => service().list(kind),
  add: (kind, id) => service().add(kind, id),
  remove: (kind, id) => service().remove(kind, id),
  listDashboards: () => service().listDashboards(),
  addDashboard: id => service().addDashboard(id),
  removeDashboard: id => service().removeDashboard(id),
};
