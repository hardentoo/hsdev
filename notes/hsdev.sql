pragma case_sensitive_like = true;

create table package_dbs (
	package_db text, -- global, user or path
	package_name text,
	package_version text
);

create view latest_packages (
	package_db,
	package_name,
	package_version
) as
select package_db, package_name, max(package_version)
from package_dbs
group by package_db, package_name;

create table projects (
	id integer primary key autoincrement,
	name text,
	cabal text,
	version text,
	package_db_stack json -- list of package-db
);

create unique index projects_id_index on projects (id);

create table libraries (
	project_id integer,
	modules json, -- list of modules
	build_info_id integer
);

create table executables (
	project_id integer,
	name text,
	path text,
	build_info_id integer
);

create table tests (
	project_id integer,
	name text,
	enabled integer,
	main text,
	build_info_id integer
);

create view targets (
	project_id,
	build_info_id
) as
select project_id, build_info_id from libraries
union
select project_id, build_info_id from executables
union
select project_id, build_info_id from tests;

create table build_infos(
	id integer primary key autoincrement,
	depends json, -- list of dependencies
	language text,
	extensions json, -- list of extensions
	ghc_options json, -- list of ghc-options
	source_dirs json, -- list of source directories
	other_modules json -- list of other modules
);

create view projects_deps (
	project_id,
	package_name,
	package_version
) as
select distinct p.id, deps.value, ps.package_version
from projects as p, build_infos as b, json_each(b.depends) as deps, targets as t, latest_packages as ps
where (p.id == t.project_id) and (b.id == t.build_info_id) and (deps.value <> p.name) and (ps.package_name == deps.value);

create view projects_modules_scope (
	project_id,
	module_id
) as
select pdbs.project_id, m.id
from projects_deps as pdbs, modules as m
where (m.package_name == pdbs.package_name) and (m.package_version == pdbs.package_version)
union
select p.id, m.id
from projects as p, modules as m
where (m.cabal == p.cabal);

create unique index build_infos_id_index on build_infos (id);

create table symbols (
	id integer primary key autoincrement,
	name text,
	module_id integer,
	docs text,
	line integer,
	column integer,
	what text, -- kind of symbol: function, method, ...
	type text,
	parent text,
	constructors json, -- list of constructors for selector
	args json, -- list of arguments for types
	context json, -- list of contexts for types
	associate text, -- associates for families
	pat_type text,
	pat_constructor text
);

create unique index symbols_id_index on symbols (id);
create index symbols_module_id_index on symbols (module_id);
create index symbols_name_index on symbols (name);

create table modules (
	id integer primary key autoincrement,
	file text,
	cabal text,
	-- project_id integer,
	install_dirs json, -- list of paths
	package_name text,
	package_version text,
	other_location text,

	name text,
	docs text,
	fixities json, -- list of fixities
	tag json,
	inspection_error text
);

create unique index modules_id_index on modules (id);
create index modules_name_index on modules (name);

create table exports (
	module_id integer,
	symbol_id integer
);

create table scopes (
	module_id integer,
	qualifier text,
	name text,
	symbol_id integer
);

create view completions (
	module_id,
	completion,
	symbol_id
) as
select id, (case when sc.qualifier is null then sc.name else sc.qualifier || '.' || sc.name end) as full_name, sc.symbol_id
from modules as m, scopes as sc
where (m.id == sc.module_id);

create table names (
	module_id integer,
	qualifier text,
	name text,
	line integer,
	column integer,
	line_to integer,
	column_to integer,
	def_line integer,
	def_column integer,
	resolved_module text,
	resolved_name text,
	resolve_error text
);