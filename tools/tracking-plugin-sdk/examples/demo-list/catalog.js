// The made-up site's catalog. A real plugin fetches these from the site's API with fushi.http.request.
// Every title and id here is invented; `linkedIds.mal` values are arbitrary numbers for the demo.
'use strict';

/** @type {FushiTracking.Subject[]} */
const SUBJECTS = [
  {
    id: 101,
    name: 'Lanterns over the Harbor',
    kind: 'anime',
    titles: ['Lanterns over the Harbor', 'みなとのランタン'],
    authors: ['Studio Placeholder'],
    totalEpisodes: 12,
    finished: true,
    linkedIds: { mal: 900101 },
  },
  {
    id: 102,
    name: 'The Quiet Orbit',
    kind: 'anime',
    titles: ['The Quiet Orbit', 'しずかな軌道'],
    totalEpisodes: 24,
    finished: false,
    linkedIds: { mal: 900102 },
  },
  {
    id: 201,
    name: 'Paper Foxes',
    kind: 'manga',
    titles: ['Paper Foxes', '紙のきつね'],
    authors: ['A. Example'],
    totalChapters: 48,
    finalVolume: 6,
    finished: true,
    linkedIds: { mal: 900201 },
  },
  {
    id: 301,
    name: 'A Library at the End of Summer',
    kind: 'novel',
    titles: ['A Library at the End of Summer', '夏の終わりの図書館'],
    authors: ['B. Example'],
    finished: false,
  },
];

/** @param {number} id */
function byId(id) {
  return SUBJECTS.find((s) => s.id === id) ?? null;
}

module.exports = { SUBJECTS, byId };
