/* ffphonelog -- finger friendly phone log
 * Copyright (C) 2009-2010 Łukasz Pankowski <lukpank@o2.pl>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

using Elm;

extern long clock();
extern const int CLOCKS_PER_SEC;

[DBus (name = "org.freesmartphone.GSM.Call")]
interface GSMCall : GLib.Object
{
    public abstract int initiate(string number, string type)
    throws DBus.Error;
}

[DBus (name = "org.freesmartphone.PIM.Calls")]
interface Calls : GLib.Object
{
    public abstract async string query(HashTable<string,Value?> query)
    throws DBus.Error;
}

[DBus (name = "org.freesmartphone.PIM.CallQuery")]
interface CallQuery : GLib.Object
{
    public abstract void Dispose() throws DBus.Error;
    public abstract int get_result_count() throws DBus.Error;
    public abstract async HashTable<string,Value?>[]
    get_multiple_results(int i) throws DBus.Error;
}

[DBus (name = "org.freesmartphone.PIM.Contact")]
interface Contact : GLib.Object
{
    public abstract HashTable<string,Value?> get_content() throws DBus.Error;
}

[DBus (name = "org.shr.phoneui.Contacts")]
interface PhoneuiContacts : GLib.Object
{
    public abstract void edit_contact(string path) throws DBus.Error;
    public abstract string create_contact(HashTable<string,Value?> values)
    throws DBus.Error;
}


DBus.Connection conn;
bool verbose = false;


void die(string msg)
{
    printerr("%s: %s\n", Environment.get_prgname(), msg);
    Posix.exit(1);
}

void print_hash_table(HashTable<string,Value?> ht)
{
    ht.foreach((key, val) => {
	    unowned Value? v = (Value?) val;
	    string s = "?";
	    string type = v.type_name() ?? @"(null type name)";
	    if (v.holds(typeof(string)))
		s = (string) v;
	    else if (v.holds(typeof(int)))
		s = v.get_int().to_string();
	    print(@"  $((string)key) : $type = $s\n");
	});
    print("\n");
}

class CallItem
{
    string peer;
    int contact;
    string name;
    bool answered;
    time_t timestamp;
    time_t duration;

    public CallItem(HashTable<string,Value?> res)
    {
	if (verbose) print_hash_table(res);
	unowned Value? v = res.lookup("Peer");
	if (v != null && v.holds(typeof(string)))
	    peer = v.get_string();
	timestamp = res.lookup("Timestamp").get_int();
	answered = res.lookup("Answered").get_int() != 0;
	duration = (answered) ?
	    res.lookup ("Duration").get_string().to_int() : 0;
	v = res.lookup("@Contacts");
	contact = (v != null && v.holds(typeof(int))) ? v.get_int() : -1;
	if (contact != -1) {
	    var path = @"/org/freesmartphone/PIM/Contacts/$contact";
	    if (verbose) print(@"$path\n");
	    var r = ((Contact) conn.get_object("org.freesmartphone.opimd",
					       path)).get_content();
	    if (verbose) print_hash_table(r);
	    v = r.lookup("Name");
	    if (v != null)
		name = v.get_string();
	}
	// XXX may also use Timezone from CallQuery result
    }

    public string? get_label(string part)
    {
	if (part == "elm.text") {
	    if (name != null)
		return @"$name ($peer)";
	    else
		return peer;
	} else if (part == "elm.text.sub") {
	    var t = GLib.Time.local(timestamp).format("%a %F %T");
	    return (answered) ? "%s,   %02u:%02u".printf(
		t, (uint) duration / 60, (uint) duration % 60) : t;
	} else {
	    return null;
	}
    }

    public void edit_add()
    {
	var o = (PhoneuiContacts) conn.get_object(
	    "org.shr.phoneui", "/org/shr/phoneui/Contacts");
	if (contact != -1) {
	    o.edit_contact(@"/org/freesmartphone/PIM/Contacts/$contact");
	} else {
	    // XXX create_contact seems to be broken in phoneui?
	    var fields = new HashTable<string,Value?>(null, null);
	    fields.insert("Name", "");
	    fields.insert("Phone", peer);
	    o.create_contact(fields);
	}
    }

    public void call()
    {
	if (peer != null)
	    ((GSMCall) conn.get_object(
		"org.freesmartphone.ogsmd",
		"/org/freesmartphone/GSM/Device")).initiate(peer, "voice");
	else
	    message("CallItem.call: will not initiate a call: peer is null\n");
    }
}

class CallsList
{
    public Genlist lst;
    GenlistItemClass itc;
    CallItem[] items;

    public CallsList(Elm.Object parent)
    {
	lst = new Genlist(parent);
	itc.item_style = "double_label";
	itc.func.label_get = (GenlistItemLabelGetFunc) get_label;
    }

    public async void populate()
    {
	conn = DBus.Bus.get(DBus.BusType.SYSTEM);
	var t = clock();
	var calls = (Calls) conn.get_object("org.freesmartphone.opimd",
					    "/org/freesmartphone/PIM/Calls");

	var q = new HashTable<string,Value?>(null, null);
	q.insert("_limit", 30);
	q.insert("_sortby", "Timestamp");
	q.insert("_sortdesc", true);
	q.insert("_resolve_phonenumber", true);
	var path = yield calls.query(q);
	var reply = (CallQuery) conn.get_object("org.freesmartphone.opimd", path);
	int cnt = reply.get_result_count();
	var results = yield reply.get_multiple_results(cnt);
	if (verbose) print(@"query: $path $cnt\n\n");
	items = new CallItem[results.length];
	int i = 0;
	foreach (var res in results) {
	    items[i] = new CallItem(res);
	    lst.item_append(itc, items[i], null, GenlistItemFlags.NONE, null);
	    i++;
	}
	print(@"populate: $((double)(clock() - t) / CLOCKS_PER_SEC)s\n");
	reply.Dispose();
    }

    static string get_label(void *data, Elm.Object? obj, string part)
    {
	return ((CallItem) data).get_label(part);
    }

    public unowned CallItem? selected_item_get()
    {
	unowned GenlistItem item = lst.selected_item_get();
	return (item != null) ? (CallItem) item.data_get() : null;
    }

    public void edit_add_selected_item()
    {
	unowned CallItem item = selected_item_get();
	if (item != null)
	    item.edit_add();
    }

    public void call_selected_item()
    {
	unowned CallItem item = selected_item_get();
	if (item != null)
	    item.call();
    }
}

class MainWin
{
    Win win;
    Bg bg;
    Box bx;
    Box bx2;
    CallsList calls;

    public MainWin()
    {
	win = new Win(null, "main", WinType.BASIC);
	if (win == null)
	    die("cannot create main window");
	win.title_set("PhoneLog");
	win.smart_callback_add("delete-request", Elm.exit);

	bg = new Bg(win);
	bg.size_hint_weight_set(1.0, 1.0);
	bg.show();
	win.resize_object_add(bg);

	bx = new Box(win);
	bx.size_hint_weight_set(1.0, 1.0);
	win.resize_object_add(bx);
	bx.show();

	calls = new CallsList(win);
	calls.populate.begin();
	calls.lst.size_hint_weight_set(1.0, 1.0);
	calls.lst.size_hint_align_set(-1.0, -1.0);
	bx.pack_end(calls.lst);
	calls.lst.show();

	bx2 = new Box(win);
	bx2.size_hint_align_set(-1.0, -1.0);
	bx2.horizontal_set(true);
	bx2.homogenous_set(true);
	bx2.show();

	add_button("Edit/Add", calls.edit_add_selected_item);
	add_button("Call", calls.call_selected_item);

	bx.pack_end(bx2);

	win.resize(480, 640);
    }

    public void show()
    {
	win.show();
    }

    void add_button(string label, Evas.Callback cb)
    {
	Button *bt = new Button(win);
	bt->label_set(label);
	bt->smart_callback_add("clicked", cb);
	bt->size_hint_weight_set(1.0, 0.0);
	bt->size_hint_align_set(-1.0, -1.0);
	bx2.pack_end(bt);
	bt->show();
    }
}

void main(string[] args)
{
    Environment.set_prgname(Path.get_basename(args[0]));
    verbose = ("-v" in args) || ("--verbose" in args);
    Elm.init(args);
    Ecore.MainLoop.glib_integrate();
    var mw = new MainWin();
    mw.show();
    Elm.run();
    Elm.shutdown();
}
