#!/usr/bin/perl -w

# This file is part of Product Opener.
#
# Product Opener
# Copyright (C) 2011-2019 Association Open Food Facts
# Contact: contact@openfoodfacts.org
# Address: 21 rue des Iles, 94100 Saint-Maur des Fossés, France
#
# Product Opener is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

use Modern::Perl '2017';
use utf8;

binmode(STDOUT, ":encoding(UTF-8)");
binmode(STDERR, ":encoding(UTF-8)");

use CGI::Carp qw(fatalsToBrowser);

use ProductOpener::Config qw/:all/;
use ProductOpener::Store qw/:all/;
use ProductOpener::Display qw/:all/;
use ProductOpener::Users qw/:all/;
use ProductOpener::Images qw/:all/;
use ProductOpener::Lang qw/:all/;
use ProductOpener::Mail qw/:all/;
use ProductOpener::Producers qw/:all/;
use ProductOpener::Text qw/:all/;

use Apache2::RequestRec ();
use Apache2::Const ();

use CGI qw/:cgi :form escapeHTML :cgi-lib/;
use URI::Escape::XS;
use Storable qw/dclone/;
use Encode;
use JSON;
use Log::Any qw($log);
use Spreadsheet::CSV();
use Text::CSV();
use boolean;

ProductOpener::Display::init();

my $action = param('action') || 'display';

my $title = lang("export_product_data_photos");
my $html = '';
my $js = '';

 if (not defined $Owner_id) {
 	display_error(lang("no_owner_defined"), 200);
}

# Require moderator status to launch the export / import process,
# unless there is only one product specified through the ?query_code= parameter
# or if the organization has the permission enable_manual_export_to_public_platform checked

my $allow_submit = ($User{moderator}
		or (defined param("query_code"))
		or ((defined $Org{enable_manual_export_to_public_platform}) and ($Org{enable_manual_export_to_public_platform} eq "on")));

if ($action eq "display") {
	
	my $template_data_ref = {
		lang => \&lang,
	};
	
	# Query filters

	my $query_ref = {};

	foreach my $param (multi_param()) {
		if ($param =~ /^query_/) {
			my $field = $';
			my $value = remove_tags_and_quote(decode utf8=>param($param));
			
			if (not defined $template_data_ref->{query_filters}) {
				$template_data_ref->{query_filters} = [];
			}
			
			push @{$template_data_ref->{query_filters}}, { field => $field, value => $value };

			$query_ref->{$field} = $value;
		}
	}
	
	# Number of products matching the optional query
	my $count = count_products({}, $query_ref);
	
	# Number of products matching the query with changes that have not yet been imported
	$query_ref->{states_tags} = "en:to-be-exported";
	my $count_to_be_exported = count_products({}, $query_ref);
	
	$template_data_ref->{count} = $count;
	$template_data_ref->{count_to_be_exported} = $count_to_be_exported;
	
	if ($count == 0) {
		$template_data_ref->{n_products_will_be_exported} = lang("no_products_to_export");
	}
	elsif ($count == 1) {
		$template_data_ref->{n_products_will_be_exported} = lang("one_product_will_be_exported");
	}
	else {
		$template_data_ref->{n_products_will_be_exported} = sprintf(lang("n_products_will_be_exported"), $count);
	}
	
	my $export_photos_value = "";
	my $replace_selected_photos_value = "";
	if ((defined $Org_id)
		and ($Org_id !~ /^(app|database|label)-/)) {
		$export_photos_value = "checked";
		$replace_selected_photos_value = "checked";
	}
	my $only_export_products_with_changes_value = "checked";
	
	$template_data_ref->{export_photos_value} = $export_photos_value;
	$template_data_ref->{replace_selected_photos_value} = $replace_selected_photos_value;
	$template_data_ref->{only_export_products_with_changes_value} = $only_export_products_with_changes_value;

	if ($allow_submit) {
		$template_data_ref->{allow_submit} = 1;
	}
	
	process_template('web/pages/export_products/export_products.tt.html', $template_data_ref, \$html) || ($html .= 'template error: ' . $tt->error());
}

elsif (($action eq "process") and $allow_submit) {
	
	# First export CSV from the producers platform, then import on the public platform
	
	my $args_ref = {
		query => { owner => $Owner_id, "data_quality_errors_producers_tags.0" => { '$exists' => false }},
	};
	
	# Add query filters

	foreach my $param (multi_param()) {
		if ($param =~ /^query_/) {
			my $query = $';
			$args_ref->{query}{$query} = remove_tags_and_quote(decode utf8=>param($param));
		}
	}
	if (not ((defined param("export_photos")) and (param("export_photos")))) {
		$args_ref->{do_not_upload_images} = 1;
	}
	
	if (not ((defined param("replace_selected_photos")) and (param("replace_selected_photos")))) {
		$args_ref->{only_select_not_existing_images} = 1;
	}
	
	if ((defined param("only_export_products_with_changes")) and (param("only_export_products_with_changes"))) {
		$args_ref->{query}{states_tags} = 'en:to-be-exported';
	}
	
	if ($admin) {
		if ((defined param("overwrite_owner")) and (param("overwrite_owner"))) {
			$args_ref->{overwrite_owner} = 1;
		}		
	}
	
	# Create Minion tasks for export and import

	my $results_ref = export_and_import_to_public_database($args_ref);
	
	my $local_export_job_id = $results_ref->{local_export_job_id};
	my $remote_import_job_id = $results_ref->{remote_import_job_id};
	my $local_export_status_job_id = $results_ref->{local_export_status_job_id};
	my $export_id = $results_ref->{export_id};
	
	$html .= "<p>" . lang("export_in_progress") . "</p>";
	
	$html .= "<p>" . lang("export_job_export") .  " - <span id=\"result1\"></span></p>";
	$html .= "<p>" . lang("export_job_import") .  " - <span id=\"result2\"></span></p>";
	$html .= "<p>" . lang("export_job_status_update") .  " - <span id=\"result3\"></span></p>";

	process_template('web/pages/import_file_process/export_products.tt.js', $template_data_ref, \$js);

	$initjs .= $js;
}
else {

	my $template_data_ref2 = {};

	# The organization does not have the permission enable_manual_export_to_public_platform checked

		my $mailto_body = URI::Escape::XS::encodeURIComponent(<<TEXT
Bonjour,
Vos produits ont été exportés vers la base publique. Voici la page publique avec vos produits : https://fr.openfoodfacts.org/editeur/org-$Org_id

Merci beaucoup pour votre démarche de transparence,
Bien cordialement,
TEXT
);

my $mailto_subject = URI::Escape::XS::encodeURIComponent(<<TEXT
Export de vos produits vers la base Open Food Facts publique
TEXT
);



	my $admin_mail_body = <<EMAIL
org_id: $Org_id <br>
<br>
user id: $User_id <br>
<br>
user name: $User{name} <br>
<br>
user email: $User{email} <br>
<br>
TODO:<br>
<br>
1. <a href="https://world.pro.openfoodfacts.org/cgi/user.pl?action=process&type=edit_owner&pro_moderator_owner=org-$Org_id">Control products on pro platform</a>. <br>
<br>
2. Validate the export. <br>
<br>
2b. Or, email to the producer if there are too many issues with their data.<br>
<br>
3. <a href="mailto:$User{email}?subject=$mailto_subject&cc=producteurs\@openfoodfacts.org&body=$mailto_body">Email to tell the producer its products have been exported</a>. <br>
<br>

EMAIL
;
	send_email_to_producers_admin(
		"Export to public database requested: user: $User_id - org: $Org_id",
		$admin_mail_body );

	process_template('web/pages/export_products_results/export_products_results.tt.html', $template_data_ref2, \$html) || ($html .= 'template error: ' . $tt->error());
	
}

display_page( {
	title=>$title,
	content_ref=>\$html,
});

exit(0);
