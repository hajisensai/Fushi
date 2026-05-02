/// Shared JavaScript for opening the bundled ttu reader's IndexedDB with the
/// same schema version and object-store layout used by ttu itself.
class TtuIdbSchema {
  const TtuIdbSchema._();

  static const int booksDbVersion = 6;

  static const String openBooksDbJs = r'''
function hibikiOpenBooksDb() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open('books', 6);
    req.onupgradeneeded = (event) => {
      const db = event.target.result;
      const tx = event.target.transaction;

      if (!db.objectStoreNames.contains("data")) {
        db.createObjectStore("data", {keyPath: "id", autoIncrement: true})
          .createIndex("title", "title");
      } else {
        const dataStore = tx.objectStore("data");
        if (dataStore.keyPath !== "id") {
          repairLegacyDataStore(db, dataStore);
        } else if (!dataStore.indexNames.contains("title")) {
          dataStore.createIndex("title", "title");
        }
      }
      if (!db.objectStoreNames.contains("bookmark")) {
        db.createObjectStore("bookmark", {keyPath: "dataId"});
      }
      if (!db.objectStoreNames.contains("lastItem")) {
        db.createObjectStore("lastItem");
      }
      if (!db.objectStoreNames.contains("storageSource")) {
        db.createObjectStore("storageSource", {keyPath: "name"});
      }
      if (!db.objectStoreNames.contains("statistic")) {
        const statistic = db.createObjectStore(
          "statistic",
          {keyPath: ["title", "dateKey"]},
        );
        statistic.createIndex("dateKey", "dateKey");
        statistic.createIndex("completedBook", ["completedBook", "title"]);
      }
      if (!db.objectStoreNames.contains("readingGoal")) {
        db.createObjectStore("readingGoal", {keyPath: "goalStartDate"})
          .createIndex("goalEndDate", "goalEndDate");
      }
      if (!db.objectStoreNames.contains("lastModified")) {
        db.createObjectStore("lastModified", {keyPath: ["title", "dataType"]});
      }
      if (!db.objectStoreNames.contains("audioBook")) {
        db.createObjectStore("audioBook", {keyPath: "title"});
      }
      if (!db.objectStoreNames.contains("subtitle")) {
        db.createObjectStore("subtitle", {keyPath: "title"});
      }
      if (!db.objectStoreNames.contains("handle")) {
        db.createObjectStore("handle", {keyPath: ["title", "dataType"]});
      }
    };
    req.onsuccess = async (event) => {
      const db = event.target.result;
      try {
        await repairLegacySectionCharacters(db);
        resolve(db);
      } catch (error) {
        db.close();
        reject(String(error));
      }
    };
    req.onerror = (event) => reject(String(event.target.error));
  });
}

function repairLegacyDataStore(db, dataStore) {
  const recordsReq = dataStore.getAll();
  recordsReq.onsuccess = () => {
    const records = recordsReq.result || [];
    db.deleteObjectStore("data");
    const repaired = db.createObjectStore(
      "data",
      {keyPath: "id", autoIncrement: true},
    );
    repaired.createIndex("title", "title");
    for (let i = 0; i < records.length; i++) {
      const record = records[i] || {};
      const id = record.id == null ? i + 1 : record.id;
      repaired.put(normalizeTtuDataRecord({...record, id: id}));
    }
  };
}

function repairLegacySectionCharacters(db) {
  return new Promise((resolve, reject) => {
    if (!db.objectStoreNames.contains("data")) {
      resolve();
      return;
    }

    const tx = db.transaction("data", "readwrite");
    const store = tx.objectStore("data");
    const recordsReq = store.getAll();

    recordsReq.onsuccess = () => {
      const records = recordsReq.result || [];
      for (const record of records) {
        const normalized = normalizeTtuDataRecord(record);
        if (normalized !== record) {
          store.put(normalized);
        }
      }
    };

    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
  });
}

function normalizeTtuDataRecord(record) {
  if (!record || !Array.isArray(record.sections)) {
    return record;
  }

  let changed = false;
  const sections = record.sections.map((section) => {
    if (
      section &&
      section.characters == null &&
      section.charactersWeight != null
    ) {
      changed = true;
      return {...section, characters: section.charactersWeight};
    }
    return section;
  });

  return changed ? {...record, sections: sections} : record;
}
''';
}
