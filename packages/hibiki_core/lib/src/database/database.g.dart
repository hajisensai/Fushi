// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
abstract class _$HibikiDatabase extends GeneratedDatabase {
  _$HibikiDatabase(QueryExecutor e) : super(e);
  $HibikiDatabaseManager get managers => $HibikiDatabaseManager(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [];
}

class $HibikiDatabaseManager {
  final _$HibikiDatabase _db;
  $HibikiDatabaseManager(this._db);
}
