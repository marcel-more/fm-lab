const favoritesService = require('../services/favorites.service');
const { buildSuccess } = require('../utils/response-builder');

/**
 * Favorites Controller — HTTP only; kind check, validation and availability
 * live in the service. Solution-independent: the handlers never read
 * req.solutionContext.
 *
 * The router is case-insensitive, so the kind is lower-cased here — the store
 * keys are lower-case.
 */

const kindOf = req => String(req.params.kind).toLowerCase();

/** GET /api/favorites/:kind */
async function list(req, res, next) {
  try {
    res.json(buildSuccess(await favoritesService.list(kindOf(req))));
  } catch (err) {
    next(err);
  }
}

/** PUT /api/favorites/:kind/:id */
async function add(req, res, next) {
  try {
    res.json(buildSuccess(await favoritesService.add(kindOf(req), req.params.id)));
  } catch (err) {
    next(err);
  }
}

/** DELETE /api/favorites/:kind/:id */
async function remove(req, res, next) {
  try {
    res.json(buildSuccess(await favoritesService.remove(kindOf(req), req.params.id)));
  } catch (err) {
    next(err);
  }
}

module.exports = {
  list,
  add,
  remove,
};
