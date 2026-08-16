import '../../features/search/search_vocabulary.dart';
import '../database/db_helper.dart';
import '../models/person_group.dart';

class PersonRepository {
  PersonRepository({DatabaseHelper? database})
      : _database = database ?? DatabaseHelper.instance;

  final DatabaseHelper _database;

  Future<List<PersonGroup>> allPeople({bool visibleOnly = true}) =>
      _database.getPersonGroupsDetailed(visibleOnly: visibleOnly);

  Future<int> candidateCount() => _database.getCandidatePersonCount();

  Future<PersonGroup?> person(String id) => _database.getPersonGroup(id);

  Future<List<PersonGroup>> peopleForAsset(String assetId) =>
      _database.getPeopleForAsset(assetId);

  Future<List<String>> assetIdsForPerson(String personId) =>
      _database.getPersonAssetIds(personId);

  Future<List<String>> indexedAssetIdsForFaceRebuild() =>
      _database.getIndexedAssetIdsOrdered();

  Future<void> rename(String personId, String name) {
    return _database.renamePerson(
      personId,
      name,
      SearchVocabulary.normalize(name),
    );
  }

  Future<void> merge(String targetId, String sourceId) =>
      _database.mergePersons(targetId, sourceId);

  Future<void> removeAsset(String personId, String assetId) =>
      _database.removeAssetFromPerson(personId, assetId);

  Future<void> resetForFaceRebuild({bool preserveNamed = true}) =>
      _database.resetPeopleForRebuild(preserveNamed: preserveNamed);
}
