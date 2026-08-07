# This file and its contents are licensed under the Apache License 2.0.
# Please see the included NOTICE for copyright information and
# LICENSE-APACHE for a copy of the license.

use strict;
use warnings;
use TimescaleNode;
use PostgreSQL::Test::Utils qw(slurp_file);
use Test::More;

my $pgaudit_library = $ENV{PGAUDIT_LIBRARY};
my $pg_pkglibdir    = $ENV{PG_PKGLIBDIR};

die 'PGAUDIT_LIBRARY is not set' unless defined $pgaudit_library;
die 'PG_PKGLIBDIR is not set'    unless defined $pg_pkglibdir;

my ($module_suffix) = $pgaudit_library =~ /pgaudit(.*)$/;
die "cannot determine module suffix from $pgaudit_library"
  unless defined $module_suffix && $module_suffix ne '';

my @library_forms = (
	{
		name      => 'bare',
		timescale => 'timescaledb',
		pgaudit   => 'pgaudit',
	},
	{
		name      => 'libdir',
		timescale => '$libdir/timescaledb',
		pgaudit   => '$libdir/pgaudit',
	},
	{
		name      => 'libdir with suffix',
		timescale => '$libdir/timescaledb' . $module_suffix,
		pgaudit   => '$libdir/pgaudit' . $module_suffix,
	},
	{
		name      => 'absolute with suffix',
		timescale => "$pg_pkglibdir/timescaledb$module_suffix",
		pgaudit   => "$pg_pkglibdir/pgaudit$module_suffix",
	},);

sub configure_node
{
	my ($name, $preload) = @_;
	my $node = TimescaleNode->new($name);

	$node->init;
	$node->append_conf('postgresql.conf',
		"shared_preload_libraries = '$preload'");
	$node->append_conf('postgresql.conf', 'logging_collector = off');
	$node->append_conf('postgresql.conf', 'log_min_messages = info');

	return $node;
}

for my $index (0 .. $#library_forms)
{
	my $form = $library_forms[$index];
	my $node = configure_node("pgaudit_safe_$index",
		"$form->{timescale},$form->{pgaudit}");

	ok($node->start, "$form->{name}: safe preload order starts");
	$node->safe_psql(
		'postgres', q[
		CREATE EXTENSION timescaledb;
		CREATE EXTENSION pgaudit;
		CREATE TABLE audit_copy(time timestamptz NOT NULL, value integer);
		SELECT create_hypertable('audit_copy', by_range('time'));
	]);

	my $log_offset = -s $node->logfile;
	# Relation logging makes stock pgAudit report the INSERT permission event
	# with the target relation instead of the relation-less COPY utility event.
	my $copy_result = $node->safe_psql(
		'postgres', q[
		SET pgaudit.log = 'write';
		SET pgaudit.log_relation = on;
		COPY audit_copy FROM STDIN WITH (FORMAT csv);
		2026-01-01 00:00:00+00,1
\.
		SELECT count(*) FROM audit_copy;
	]);

	is($copy_result, '1', "$form->{name}: COPY inserts exactly one row");
	my $copy_log = slurp_file($node->logfile, $log_offset);
	my @copy_audit_records =
	  $copy_log =~ /AUDIT:.*COPY audit_copy FROM STDIN[^\n]*/g;
	is(scalar @copy_audit_records,
		1, "$form->{name}: COPY emits exactly one pgAudit record");
	my @audit_records =
	  $copy_log =~
	  /AUDIT:.*WRITE,INSERT,TABLE,public\.audit_copy,.*COPY audit_copy FROM STDIN/g;
	is(scalar @audit_records,
		1, "$form->{name}: COPY emits one complete pgAudit WRITE record");
	unlike(
		$copy_log,
		qr/pgaudit stack is empty/,
		"$form->{name}: COPY does not lose pgAudit stack state");
	$node->stop;
}

for my $index (0 .. $#library_forms)
{
	my $form = $library_forms[$index];
	my $node = configure_node("pgaudit_unsafe_$index",
		"$form->{pgaudit},$form->{timescale}");

	ok(!$node->start(fail_ok => 1),
		"$form->{name}: reverse preload order refuses startup");
	my $startup_log = slurp_file($node->logfile);
	like(
		$startup_log,
		qr/pgaudit must be listed after timescaledb in shared_preload_libraries/,
		"$form->{name}: startup error identifies the ordering problem");
	like(
		$startup_log,
		qr/shared_preload_libraries = 'timescaledb,pgaudit'.*restart PostgreSQL/s,
		"$form->{name}: startup error provides reorder and restart instructions"
	);
}

my $placeholder_node = configure_node('pgaudit_placeholder', 'timescaledb');
$placeholder_node->append_conf('postgresql.conf', "pgaudit.log = 'write'");
ok($placeholder_node->start,
	'pgAudit placeholder GUC without preload does not cause an ordering error'
);
is( $placeholder_node->safe_psql(
		'postgres', 'CREATE EXTENSION timescaledb; SELECT 1'),
	'1',
	'TimescaleDB remains usable with a pgAudit placeholder GUC');
unlike(
	slurp_file($placeholder_node->logfile),
	qr/pgaudit must be listed after timescaledb/,
	'placeholder GUC does not produce the preload-order diagnostic');
$placeholder_node->stop;

done_testing();

1;
