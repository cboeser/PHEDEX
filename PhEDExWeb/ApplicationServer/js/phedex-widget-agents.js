// instantiate the PHEDEX.Widget.Agents namespace
PHEDEX.namespace('Widget.Agents');

agents=function(divid) {
  var site = document.getElementById(divid+'_select').value;
  var agent_node = new PHEDEX.Widget.Agents(divid,site);
  agent_node.update();
}

PHEDEX.Widget.Agents=function(divid,site) {
	var that=new PHEDEX.Core.Widget(divid+'_'+site,null,
		{
		children:false,
		width:500,
		height:200,
		minwidth:300,
		minheight:80
		});
	that.site=site;
	that.data = null;
	that.buildHeader=function(div) {
          var now = new Date() / 1000;
          var minDate = now;
          var maxDate = 0;
          for ( var i in this.data) {
	    var a = this.data[i];
            var u = a['time_update'];
            a['gmtDate'] = new Date(u*1000).toGMTString();
            if ( u > maxDate ) { maxDate = u; }
            if ( u < minDate ) { minDate = u; }
          }
	  var msg = "Site: "+this.site+", agents: "+this.data.length;
          if ( maxDate > 0 )
          {
            var minGMT = new Date(minDate*1000).toGMTString();
            var maxGMT = new Date(maxDate*1000).toGMTString();
            var dMin = Math.round(now - minDate);
            var dMax = Math.round(now - maxDate);
            msg += " Update-times range: "+dMin+" - "+dMax+" seconds ago";
          }
          div.innerHTML = msg;
	}
	that.buildBody=function(div) {
	  var table = [];
	  for (var i in this.data) {
	    var a = this.data[i];
            var y = { Agent:a['name'], Version:a['version'], PID:a['pid'], Date:a['gmtDate'] };
            table.push( y );
          }
          var columnDefs = [
	            {key:"Agent", sortable:true, resizeable:true},
	            {key:"Version", sortable:true, resizeable:true},
	            {key:"PID", sortable:true, resizeable:true},
	            {key:"Date", formatter:YAHOO.widget.DataTable.formatDate, sortable:true, resizeable:true},
	        ];
          var dataSource = new YAHOO.util.DataSource(table);
	        dataSource.responseType = YAHOO.util.DataSource.TYPE_JSARRAY;
	        dataSource.responseSchema = {
	            fields: ["Agent","Version","PID","Date"]
	        };
        var dataTable = new YAHOO.widget.DataTable(div, columnDefs, dataSource,
                     {
                      draggableColumns:true
                     });
	}
	that.buildFooter = function() {}
	that.update=function() {
	  PHEDEX.Datasvc.Agents(site,this); // this.receive,this);
	}
	that.receive=function(result) {
	  var data = PHEDEX.Data.Agents;
	  if (data) {
	    that.data = data[site];
	    that.build();
	    }
	}
	return that;
}
