/*
 * Small helpers shared by the plugin's server-side DataTables.
 *
 * Koha 25.11 ships DataTables 2.x, which dropped the legacy "fnServerData"
 * callback and the "jquery.dataTables.columnFilter.js" plugin this codebase
 * used to depend on no longer ships with Koha at all. These helpers replace
 * both with DataTables-2-native mechanisms (the "ajax" function option and
 * per-column "search()") while keeping the exact query parameters the
 * plugin's own REST endpoints already expect, so no Perl-side changes are
 * required. They work identically on Koha 22.11 (DataTables 1.10, which
 * already understands the "ajax" function option and per-column search).
 */

/*
 * Build a Koha-style "_order_by" string ("+field,-field2") from a
 * DataTables-2 ajax "data" object.
 *
 * opts:
 *   fieldMap:      { columnDataName: 'query_param_name', ... }
 *   splitCompound: if true, the source string "a:b:c" sorts by all of
 *                  a, b and c (used where one rendered column maps to
 *                  several real DB columns)
 *   qualifyPrefix: prefix added to any field that has no "." in it yet
 *                  (e.g. "me." so bare columns are qualified for the ORM)
 *   sourceField:   which column-request property holds the sort field(s) -
 *                  "data" (default) or "name". Use "name" when "data" must
 *                  stay a real, single row property (so DataTables can look
 *                  up a value for it without warning) while the sortable
 *                  field list lives in "name" instead.
 */
function lmscOrderBy(data, opts) {
    opts = opts || {};
    var fieldMap = opts.fieldMap || {};
    var sourceField = opts.sourceField || "data";

    if (!data.order || !data.order.length) {
        return "";
    }

    var parts = [];
    data.order.forEach(function (order) {
        var column = data.columns[order.column];
        var source = column && column[sourceField];
        if (!source) {
            return;
        }
        var dir = order.dir === "desc" ? "-" : "+";
        var fields = opts.splitCompound ? source.split(":") : [source];
        fields.forEach(function (field) {
            if (fieldMap[field]) {
                field = fieldMap[field];
            }
            if (opts.qualifyPrefix && field.indexOf(".") === -1) {
                field = opts.qualifyPrefix + field;
            }
            parts.push(dir + field);
        });
    });

    return parts.filter(function (value, index, all) {
        return all.indexOf(value) === index;
    }).join(",");
}

/*
 * Turn a DataTables-2 ajax "data" object's paging fields into the Koha REST
 * pagination params ("_page" is 1-based, unlike DataTables' 0-based "start").
 */
function lmscPaging(data) {
    return {
        _page: Math.floor(data.start / data.length) + 1,
        _per_page: data.length,
        draw: data.draw,
    };
}

/*
 * Read the range value ("from~to") DataTables holds for a column and split
 * it into its two parts. Used for both number-range and date-range filters,
 * matching the "~"-separated convention the old columnFilter plugin used
 * (some of the plugin's REST endpoints already split incoming values on
 * "~" server-side, e.g. LatePaymentClaiming.pm's "account_balance" filter).
 */
function lmscSplitRange(value) {
    var parts = (value || "").split("~");
    return { from: parts[0] || "", to: parts[1] || "" };
}

/*
 * Build a filter row under a DataTable's header and wire it to the table's
 * per-column search (DataTables-2 native), replacing the old
 * "jquery.dataTables.columnFilter.js" plugin.
 *
 * dt: the DataTables API instance (result of $(...).DataTable() / .dataTable().api())
 * columnDefs: array parallel to the table's columns; each entry is either
 *   null                                    -> no filter for this column
 *   { type: 'text' }
 *   { type: 'select', values: [{label,value}, ...] }
 *   { type: 'number-range' }
 *   { type: 'date-range' }
 */
function lmscBuildFilterRow(dt, columnDefs) {
    var $table = $(dt.table().node());
    var tableId = $table.attr("id");
    /*
     * The plugin's tables ship with two <thead> rows: a "nice" one with
     * soft-hyphenated column labels, and a plain-text one used as a fallback
     * (originally intended for the old columnFilter plugin to repurpose into
     * the filter row). Reuse that existing second row instead of appending a
     * brand new one, so the table keeps the two rows its CSS already targets
     * via ":nth-child(2)" (e.g. the "#latePaymentCurrentClaims table
     * thead tr:nth-child(2) th" rules in latepaymentclaiming.css).
     */
    var $headerRows = $table.find("thead tr");
    var $labelRow = $headerRows.eq(0);
    var $filterRow = $headerRows.length > 1 ? $headerRows.eq(1) : $headerRows.last();
    var $cells = $filterRow.find("th");
    var $labelCells = $labelRow.find("th");

    columnDefs.forEach(function (def, i) {
        var $th = $cells.eq(i);

        if (!$th.length || !def) {
            return;
        }

        // Row 1 already shows the column's own label - reuse its text as
        // the filter's placeholder / blank-option wording (matching what the
        // pre-migration filters showed), then drop the duplicate label that
        // used to sit in this cell before adding the filter widget.
        var label = $labelCells.eq(i).text().trim();
        $th.empty();

        var current = dt.column(i).search() || "";

        if (def.type === "select") {
            var $select = $('<select class="select_filter"></select>');
            $select.append($("<option></option>").attr("value", "").text(label ? "Auswahl " + label : ""));
            def.values.forEach(function (opt) {
                var $opt = $("<option></option>").attr("value", opt.value).text(opt.label);
                if (current !== "" && String(current) === String(opt.value)) {
                    $opt.prop("selected", true);
                }
                $select.append($opt);
            });
            $select.on("change", function () {
                dt.column(i).search($(this).val()).draw();
            });
            $th.append($('<span class="filter_column filter_select"></span>').append($select));
        } else if (def.type === "number-range" || def.type === "date-range") {
            var fromId = tableId + "_range_from_" + i;
            var toId = tableId + "_range_to_" + i;
            var range = lmscSplitRange(current);
            var isDateRange = def.type === "date-range";
            var inputClass = isDateRange ? "date_range_filter flatpickr" : "number_range_filter";
            var inputSize = isDateRange ? "8" : "5";

            var $wrap = $('<span class="filter_column"></span>').addClass(
                isDateRange ? "filter_date_range" : "filter_number_range"
            );
            var $from = $("<input type=\"text\" size=\"" + inputSize + "\">").attr("id", fromId).addClass(inputClass).val(range.from);
            var $to = $("<input type=\"text\" size=\"" + inputSize + "\">").attr("id", toId).addClass(inputClass).val(range.to);

            var $fromLine = $('<span></span>').css("white-space", "nowrap").append($("<span>Von </span>"), $from);
            var $toLine = $('<span></span>').css("white-space", "nowrap").append($("<span>bis </span>"), $to);
            $wrap.append($fromLine, $("<br>"), $toLine);
            // Right-align both lines so the "Von"/"bis" inputs' edges line
            // up in a column, regardless of the two labels' text width.
            $th.css("text-align", "right");
            $th.append($wrap);

            var applyRange = function (event) {
                if (event && event.target && event.target._flatpickr) {
                    event.target._flatpickr.close();
                }
                var from = $from.val();
                var to = $to.val();
                dt.column(i).search(from || to ? from + "~" + to : "").draw();
            };

            if (isDateRange) {
                flatpickr($from[0], {});
                flatpickr($to[0], {});
                $from.add($to).on("change", applyRange);
            } else {
                var rangeTimer;
                $from.add($to).on("keyup", function (event) {
                    window.clearTimeout(rangeTimer);
                    rangeTimer = window.setTimeout(function () {
                        applyRange(event);
                    }, 400);
                });
            }
        } else {
            var $wrapText = $('<span class="filter_column"></span>');
            var $input = $('<input type="text">').attr("placeholder", label).val(current);
            var timer;
            $input.on("keyup", function () {
                var value = $(this).val();
                window.clearTimeout(timer);
                timer = window.setTimeout(function () {
                    dt.column(i).search(value).draw();
                }, 400);
            });
            $wrapText.append($input);
            $th.append($wrapText);
        }
    });
}
