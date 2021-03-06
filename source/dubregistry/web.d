/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.web;

import dubregistry.dbcontroller;
import dubregistry.repositories.bitbucket;
import dubregistry.repositories.github;
import dubregistry.registry;
import dubregistry.viewutils; // dummy import to make rdmd happy

import dub.semver;
import std.algorithm : sort, startsWith;
import std.array;
import std.file;
import std.path;
import std.string;
import userman.web;
import vibe.d;

class DubRegistryWebFrontend {
	private {
		struct Category { string name, description, indentedDescription, imageName; }

		DubRegistry m_registry;
		UserManController m_userman;
		UserManWebInterface m_usermanweb;
		Category[] m_categories;
		Category[string] m_categoryMap;
	}

	this(DubRegistry registry, UserManController userman)
	{
		m_registry = registry;
		m_userman = userman;
		m_usermanweb = new UserManWebInterface(userman);

		updateCategories();
	}

	void register(URLRouter router)
	{
		m_usermanweb.register(router);

		// user front end
		router.get("/", &showHome);
		router.get("/search", &showSearchResults);
		router.get("/about", staticTemplate!"usage.dt");
		router.get("/usage", staticRedirect("/about"));
		router.get("/download", &showDownloads);
		router.get("/publish", staticTemplate!"publish.dt");
		router.get("/develop", staticTemplate!"develop.dt");
		router.get("/package-format", staticTemplate!"package_format.dt");
		router.get("/available", &showAvailable);
		router.get("/packages/index.json", &showAvailable);
		router.get("/packages/:packname", &showPackage); // HTML or .json
		router.get("/packages/:packname/:version", &showPackageVersion); // HTML or .zip or .json
		router.get("/view_package/:packname", &redirectViewPackage);
		router.get("/my_packages", m_usermanweb.auth(toDelegate(&showMyPackages)));
		router.get("/my_packages/register", m_usermanweb.auth(toDelegate(&showAddPackage)));
		router.post("/my_packages/register", m_usermanweb.auth(toDelegate(&addPackage)));
		router.get("/my_packages/:packname", m_usermanweb.auth(toDelegate(&showMyPackagesPackage)));
		router.post("/my_packages/:packname/update", m_usermanweb.auth(toDelegate(&updatePackage)));
		router.post("/my_packages/:packname/remove", m_usermanweb.auth(toDelegate(&showRemovePackage)));
		router.post("/my_packages/:packname/remove_confirm", m_usermanweb.auth(toDelegate(&removePackage)));
		router.post("/my_packages/:packname/set_categories", m_usermanweb.auth(toDelegate(&updatePackageCategories)));
		router.post("/my_packages/:packname/set_repository", m_usermanweb.auth(toDelegate(&updatePackageRepository)));
		router.get("*", serveStaticFiles("./public"));
	}

	void showAvailable(HTTPServerRequest req, HTTPServerResponse res)
	{
		res.writeJsonBody(m_registry.availablePackages.array);
	}

	void showHome(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto sort_by = req.query.get("sort", "updated");
		auto category = req.query.get("category", null);


		// collect the package list
		auto packapp = appender!(Json[])();
		packapp.reserve(200);
		if (category.length) {
			foreach (pname; m_registry.availablePackages) {
				auto pack = m_registry.getPackageInfo(pname);
				foreach (c; pack.categories) {
					if (c.get!string.startsWith(category)) {
						packapp.put(pack);
						break;
					}
				}
			}
		} else {
			foreach (pack; m_registry.availablePackages)
				packapp.put(m_registry.getPackageInfo(pack));
		}
		auto packages = packapp.data;

		// sort by date of last version
		string getDate(Json p) {
			if( p.type != Json.Type.Object || "versions" !in p ) return null;
			if( p.versions.length == 0 ) return null;
			return p.versions[p.versions.length-1].date.get!string;
		}
		SysTime getDateAdded(Json p) {
			return SysTime.fromISOExtString(p.dateAdded.get!string);
		}
		bool compare(Json a, Json b) {
			bool a_has_ver = a.versions.get!(Json[]).any!(v => !v["version"].get!string.startsWith("~"));
			bool b_has_ver = b.versions.get!(Json[]).any!(v => !v["version"].get!string.startsWith("~"));
			if (a_has_ver != b_has_ver) return a_has_ver;
			return getDate(a) > getDate(b);
		}
		switch (sort_by) {
			default: sort!((a, b) => compare(a, b))(packages); break;
			case "name": sort!((a, b) => a.name < b.name)(packages); break;
			case "added": sort!((a, b) => getDateAdded(a) > getDateAdded(b))(packages); break;
		}

		res.renderCompat!("home.dt",
			HTTPServerRequest, "req",
			Category[], "categories",
			Category[string], "categoryMap",
			Json[], "packages")(req, m_categories, m_categoryMap, packages);
	}

	void showSearchResults(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto queryString = req.query.get("q", "");
		auto keywords = queryString.split();
		auto results = m_registry.searchPackages(keywords);
		res.render!("search_results.dt", req, queryString, results);
	}

	void showDownloads(HTTPServerRequest req, HTTPServerResponse res)
	{
		static struct DownloadFile {
			string fileName;
			string platformCaption;
			string typeCaption;
		}

		static struct DownloadVersion {
			string id;
			DownloadFile[][string] files;
		}

		static struct Info {
			DownloadVersion[] versions;
			void addFile(string ver, string platform, string filename)
			{

				auto df = DownloadFile(filename);
				switch (platform) {
					default:
						auto pts = platform.split("-");
						df.platformCaption = format("%s%s (%s)", pts[0][0 .. 1].toUpper(), pts[0][1 .. $], pts[1].replace("_", "-").toUpper());
						break;
					case "osx-x86": df.platformCaption = "OS X (X86)"; break;
					case "osx-x86_64": df.platformCaption = "OS X (X86-64)"; break;
				}

				if (filename.endsWith(".tar.gz")) df.typeCaption = "binary tarball";
				else if (filename.endsWith(".zip")) df.typeCaption = "zipped binaries";
				else if (filename.endsWith(".rpm")) df.typeCaption = "binary RPM package";
				else if (filename.endsWith("setup.exe")) df.typeCaption = "installer";
				else df.typeCaption = "Unknown";

				foreach(ref v; versions)
					if( v.id == ver ){
						v.files[platform] ~= df;
						return;
					}
				DownloadVersion dv = DownloadVersion(ver);
				dv.files[platform] = [df];
				versions ~= dv;
			}
		}

		Info info;

		import std.regex;
		static Regex!char[][string] platformPatterns;
		if (platformPatterns.length == 0) {
			platformPatterns["windows-x86"] = [
				regex("^dub-(?P<version>[^-]+)(?:-(?P<prerelease>.*))?(?:-setup\\.exe|-windows-x86\\.zip)$")
			];
			platformPatterns["linux-x86_64"] = [
				regex("^dub-(?P<version>[^-]+)(?:-(?P<prerelease>.+))?-linux-x86_64\\.tar\\.gz$"),
				regex("^dub-(?P<version>[^-]+)-(?:0\\.(?P<prerelease>.+)|[^0].*)\\.x86_64\\.rpm$")
			];
			platformPatterns["linux-x86"] = [
				regex("^dub-(?P<version>[^-]+)(?:-(?P<prerelease>.+))?-linux-x86\\.tar\\.gz$"),
				regex("^dub-(?P<version>[^-]+)-(?:0\\.(?P<prerelease>.+)|[^0].*)\\.x86\\.rpm$")
			];
			platformPatterns["osx-x86_64"] = [
				regex("^dub-(?P<version>[^-]+)(?:-(?P<prerelease>.+))?-osx-x86_64\\.tar\\.gz$"),
			];
		}

		foreach(de; dirEntries("public/files", "*.*", SpanMode.shallow)){
			auto name = Path(de.name).head.toString();

			foreach (platform, rexes; platformPatterns) {
				foreach (rex; rexes) {
					auto match = match(name, rex).captures;//matchFirst(name, rex);
					if (match.empty) continue;
					auto ver = match["version"] ~ (match["prerelease"].length ? "-" ~ match["prerelease"] : "");
					if (!ver.isValidVersion()) continue;
					info.addFile(ver, platform, name);
				}
			}
		}

		info.versions.sort!((a, b) => vcmp(a.id, b.id))();

		res.renderCompat!("download.dt",
			HTTPServerRequest, "req",
			Info*, "info")(req, &info);
	}

	void redirectViewPackage(HTTPServerRequest req, HTTPServerResponse res)
	{
		res.redirect("/packages/"~req.params["packname"]);
	}

	void showPackage(HTTPServerRequest req, HTTPServerResponse res)
	{
		bool json = false;
		auto pname = req.params["packname"].urlDecode();
		if( pname.endsWith(".json") ){
			pname = pname[0 .. $-5];
			json = true;
		}

		Json packageInfo, versionInfo;
		if (!getPackageInfo(pname, null, packageInfo, versionInfo))
			return;

		auto user = m_userman.getUser(BsonObjectID.fromHexString(packageInfo.owner.get!string));

		if (json) {
			if (pname.canFind(":")) return;
			res.writeJsonBody(packageInfo);
		} else {
			res.renderCompat!("view_package.dt",
				HTTPServerRequest, "req", 
				string, "packageName",
				User, "user",
				Json, "packageInfo",
				Json, "versionInfo")(req, pname, user, packageInfo, versionInfo);
		}
	}

	void showPackageVersion(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto pname = req.params["packname"].urlDecode();

		auto ver = req.params["version"].replace(" ", "+");
		string ext;
		if( ver.endsWith(".zip") ) ext = "zip", ver = ver[0 .. $-4];
		else if( ver.endsWith(".json") ) ext = "json", ver = ver[0 .. $-5];

		Json packageInfo, versionInfo;
		if (!getPackageInfo(pname, ver, packageInfo, versionInfo))
			return;

		auto user = m_userman.getUser(BsonObjectID.fromHexString(packageInfo.owner.get!string));

		if (ext == "zip") {
			if (pname.canFind(":")) return;
			// add download to statistic
			m_registry.addDownload(BsonObjectID.fromString(packageInfo.id.get!string), ver, req.headers.get("User-agent", null));
			// redirect to hosting service specific URL
			res.redirect(versionInfo.downloadUrl.get!string);
		} else if ( ext == "json") {
			if (pname.canFind(":")) return;
			res.writeJsonBody(versionInfo);
		} else {
			res.renderCompat!("view_package.dt",
				HTTPServerRequest, "req", 
				string, "packageName",
				User, "user",
				Json, "packageInfo",
				Json, "versionInfo")(req, pname, user, packageInfo, versionInfo);
		}
	}

	private bool getPackageInfo(string pack_name, string pack_version, out Json pkg_info, out Json ver_info)
	{
		auto ppath = pack_name.urlDecode().split(":");

		pkg_info = m_registry.getPackageInfo(ppath[0]);
		if (pkg_info == null) return false;

		if (pack_version.length) {
			foreach (v; pkg_info.versions) {
				if (v["version"].get!string == pack_version) {
					ver_info = v;
					break;
				}
			}
			if (ver_info.type != Json.Type.Object) return false;
		} else {
			import dubregistry.viewutils;
			if (pkg_info.versions.length == 0) return false;
			ver_info = getBestVersion(pkg_info.versions);
		}

		foreach (i; 1 .. ppath.length) {
			if ("subPackages" !in ver_info) return false;
			bool found = false;
			foreach (sp; ver_info.subPackages) {
				if (sp.name == ppath[i]) {
					Json newv = Json.emptyObject;
					// inherit certain fields
					foreach (field; ["version", "date", "license", "authors", "homepage"])
						if (auto pv = field in ver_info) newv[field] = *pv;
					// copy/overwrite the rest frmo the sub package
					foreach (string name, value; sp) newv[name] = value;
					ver_info = newv;
					found = true;
					break;
				}
			}
			if (!found) return false;
		}
		return true;
	}

	void showMyPackages(HTTPServerRequest req, HTTPServerResponse res, User user)
	{
		res.renderCompat!("my_packages.dt",
			HTTPServerRequest, "req",
			User, "user",
			DubRegistry, "registry")(req, user, m_registry);
	}

	void showMyPackagesPackage(HTTPServerRequest req, HTTPServerResponse res, User user)
	{
		auto packageName = req.params["packname"];
		auto nfo = m_registry.getPackageInfo(packageName);
		if (nfo.type == Json.Type.null_) return;
		enforceUserPackage(user, packageName);
		res.renderCompat!("my_packages.package.dt",
			HTTPServerRequest, "req",
			string, "packageName",
			Category[], "categories",
			User, "user",
			DubRegistry, "registry")(req, packageName, m_categories, user, m_registry);
	}

	void showAddPackage(HTTPServerRequest req, HTTPServerResponse res, User user)
	{
		string error = req.params.get("error", null);
		res.renderCompat!("my_packages.register.dt",
			HTTPServerRequest, "req",
			User, "user",
			string, "error",
			DubRegistry, "registry")(req, user, error, m_registry);
	}

	void addPackage(HTTPServerRequest req, HTTPServerResponse res, User user)
	{
		Json rep = Json.emptyObject;
		rep["kind"] = req.form["kind"];
		rep["owner"] = req.form["owner"];
		rep["project"] = req.form["project"];
		try m_registry.addPackage(rep, user._id);
		catch (Exception e) {
			req.params["error"] = e.msg;
			showAddPackage(req, res, user);
			return;
		}

		res.redirect("/my_packages");
	}

	void updatePackage(HTTPServerRequest req, HTTPServerResponse res, User user)
	{
		auto pack_name = req.params["packname"];
		enforceUserPackage(user, pack_name);
		m_registry.triggerPackageUpdate(pack_name);
		res.redirect("/my_packages/"~pack_name);
	}

	void showRemovePackage(HTTPServerRequest req, HTTPServerResponse res, User user)
	{
		auto packageName = req.params["packname"];
		enforceUserPackage(user, packageName);
		res.renderCompat!("my_packages.remove.dt",
			HTTPServerRequest, "req",
			string, "packageName",
			User, "user")(req, packageName, user);
	}

	void removePackage(HTTPServerRequest req, HTTPServerResponse res, User user)
	{
		auto pack_name = req.params["packname"];
		enforceUserPackage(user, pack_name);
		m_registry.removePackage(pack_name, user._id);
		res.redirect("/my_packages");
	}

	void updatePackageCategories(HTTPServerRequest req, HTTPServerResponse res, User user)
	{
		auto pack_name = req.params["packname"];
		enforceUserPackage(user, pack_name);
		string[] categories;
		outer: foreach (i; 0 .. 100) {
			auto pv = format("category%d", i) in req.form;
			if (!pv) break;
			string cat = *pv;
			if (cat.length == 0) continue;
			foreach (j, ec; categories) {
				if (cat.startsWith(ec)) continue outer;
				if (ec.startsWith(cat)) {
					categories[j] = cat;
					continue outer;
				}
			}
			categories ~= cat;
		}
		m_registry.setPackageCategories(pack_name, categories);
		res.redirect("/my_packages/"~pack_name);
	}

	void updatePackageRepository(HTTPServerRequest req, HTTPServerResponse res, User user)
	{
		auto pack_name = req.params["packname"];
		enforceUserPackage(user, pack_name);

		Json rep = Json.emptyObject;
		rep["kind"] = req.form["kind"];
		rep["owner"] = req.form["owner"];
		rep["project"] = req.form["project"];

		try m_registry.setPackageRepository(pack_name, rep);
		catch (Exception e) {
			req.params["updateRepositoryError"] = e.msg;
			showMyPackagesPackage(req, res, user);
			return;
		}

		res.redirect("/my_packages/"~pack_name);
	}

	private void enforceUserPackage(User user, string package_name)
	{
		enforceHTTP(m_registry.isUserPackage(user._id, package_name), HTTPStatus.forbidden, "You don't have access rights for this package.");
	}

	private void updateCategories()
	{
		auto catfile = openFile("categories.json");
		scope(exit) catfile.close();
		auto json = parseJsonString(catfile.readAllUTF8());

		Category[] cats;
		void processNode(Json node, string[] path)
		{
			path ~= node.name.get!string;
			Category cat;
			cat.name = path.join(".");
			cat.description = node.description.get!string;
			if (path.length > 2)
				cat.indentedDescription = "\u00a0\u00a0\u00a0\u00a0".replicate(path.length-2) ~ "\u00a0└ " ~ cat.description;
			else if (path.length == 2)
				cat.indentedDescription = "\u00a0└ " ~ cat.description;
			else cat.indentedDescription = cat.description;
			foreach_reverse (i; 0 .. path.length)
				if (existsFile("public/images/categories/"~path[0 .. i].join(".")~".png")) {
					cat.imageName = path[0 .. i].join(".");
					break;
				}
			cats ~= cat;
			if ("categories" in node)
				foreach (subcat; node.categories)
					processNode(subcat, path);
		}
		foreach (top_level_cat; json)
			processNode(top_level_cat, null);
		m_categories = cats;

		m_categoryMap = null;
		foreach (c; m_categories) m_categoryMap[c.name] = c;
	}
}
