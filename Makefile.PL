#!/usr/bin/perl
use 5.008;
use ExtUtils::MakeMaker;
WriteMakefile(
	NAME => 'DJabberd::Plugin::Push',
	VERSION_FROM => 'lib/DJabberd/Plugin/Push.pm',
	ABSTRACT_FROM => 'lib/DJabberd/Plugin/Push.pm',
	PREREQ_PM => {
		'DJabberd' => '0.85',
	},
	AUTHOR => 'Ruslan N. Marchenko <me@ruff.mobi>',
);
