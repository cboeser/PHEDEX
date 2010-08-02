// Utility functions, not PhEDEx-specific, such as adding listeners for on-load etc.
PHEDEX.namespace('Util');

PHEDEX.Util.findOrCreateWidgetDiv = function(name,container)
{
// Find a div named 'name' and return it. If that div doesn't exist, create it, append it to a div called
// 'phedex-main', and then return it. This lets me create widgets in the top-level phedex-main div, on demand.
  if ( !container ) { container = 'phedex-main'; }
  var div = document.getElementById(name);
  if ( !div )
  {
    div = document.createElement('div');
    div.id = name;
    var parent = document.getElementById(container);
    if (!parent) {
      throw new Error('could not find parent container '+container);
    }
    parent.appendChild(div);
  }
  return div;
}

// generate a new and page-unique name to use for a div for instantiating on-the-fly widgets
PHEDEX.Util.generateDivName=function(prefix) {
  var j = ++PHEDEX.Page.Config.Count;
  if ( ! prefix ) { prefix = 'phedex-auto-widget'; }
  return prefix+'-'+j;
}

// not used. Creates a UL from an array of strings
PHEDEX.Util.makeUList = function(args) {
  var i, li, list = document.createElement('ul');
  for (i in args)
  {
    li = document.createElement('li');
    li.innerHTML = args[i];
    list.appendChild(li);
  }
  return list;
}

// Make a child node of some kind
PHEDEX.Util.makeChild = function(parent, kind, args) {
  // Optionally get the parent by id
  if (typeof(parent) != 'object') {
    parent = document.getElementById(parent); 
  }
  if (!parent) { throw new Error("cannot makeChild:  parent is not set"); }
  if (!kind)   { throw new Error("cannot makeChild:  kind is not set"); }

  var a, child = document.createElement(kind);
  if (!child)   { throw new Error("cannot makeChild:  bad child type?"); }
  for (a in args) {
    child[a] = args[a];
  }
  parent.appendChild(child);
  return child;
}

PHEDEX.Util.format={
    bytes:function(raw) {
      var f = parseFloat(raw);
      if (f>=1099511627776) return (f/1099511627776).toFixed(1)+' TB';
      if (f>=1073741824) return (f/1073741824).toFixed(1)+' GB';
      if (f>=1048576) return (f/1048576).toFixed(1)+' MB';
      if (f>=1024) return (f/1024).toFixed(1)+' KB';
      return f.toFixed(0)+' B';
    },
    '%':function(raw) {
      return (100*parseFloat(raw)).toFixed(2)+'%';
    },
    longString:function(raw) {
      return "<acronym title='"+raw+"'>"+raw+"</acronym>";
    },
    block:function(raw) {
      if (raw.length>50) {
        var _short = raw.substring(0,50);
        return "<acronym title='"+raw+"'>"+_short+"...</acronym>";
      } else {
        return raw;
      }
    },
    file:function(raw) {
      if (raw.length>50) {
        var _short = raw.substring(0,50);
        return "<acronym title='"+raw+"'>"+_short+"...</acronym>";
      } else {
        return raw;
      }
    },
    date:function(raw) {
      var d =new Date(parseFloat(raw)*1000);
      return d.toGMTString();
    },
    dataset:function(raw) {
      if (raw.length>50) {
        var _short = raw.substring(0,50);
        return "<acronym title='"+raw+"'>"+_short+"...</acronym>";
      } else {
        return raw;
      }
    },
    filesBytes:function(f,b) {
//    allow a single object to be passed in instead of two literals
      if ( typeof(f) == 'object' ) { b = f.bytes; f=f.files; }
      var str = f+' files';
      if ( f > 0  ) { str += " / "+PHEDEX.Util.format.bytes(b); }
      return str;
    },
    spanWrap:function(raw) {
//    wrap the raw data in a span, to allow it to be tagged/found in the DOM. Can use this for detecting long
//    strings that are partially hidden because the div is too short, and show a tooltip or something...
      return "<span class='span-wrap'>"+raw+"</span>";
    },
    toFixed: function(mantissa) {
      return function(raw) {
        return raw.toFixed(mantissa);
      }
    }
}

PHEDEX.Util.Sort={
  alpha: {
    asc: function (a,b) {
      if ( a > b ) { return  1; }
      if ( a < b ) { return -1; }
      return 0;
    },
    desc: function (a,b) {
      if ( a > b ) { return -1; }
      if ( a < b ) { return  1; }
      return 0;
    }
  },
  numeric: {
    asc:  function(a,b) { return a-b; },
    desc: function(a,b) { return b-a; }
  },
  files: {
    asc:  function(a,b) { return a.files-b.files; },
    desc: function(a,b) { return b.files-a.files; }
  },
  bytes: {
    asc:  function(a,b) { return a.bytes-b.bytes; },
    desc: function(a,b) { return b.bytes-a.bytes; }
  }
};

// for a given element, return the global configuration object defined for it. This allows to find configurations
// for elements created on the fly. If no configuration found, return a correct empty object, to avoid the need
// for messy nested existence checks in the client code
PHEDEX.Util.getConfig=function(element) {
  var config = PHEDEX.Page.Config.Elements[element];
  if ( config ) { return config; }
  config={};
  config.opts = {};
  return config;
}

// generate a new and page-unique name to use for a div for instantiating on-the-fly widgets
PHEDEX.Util.Sequence=function() {
  var _seqArr = {},
      _seq = 0;
  return function(name) {
    if ( !name ) { return _seq++; }
    if (!_seqArr[name] ) { _seqArr[name] = 0; }
    return _seqArr[name]++;
  }
}();

// Sum an array-field, with an optional parser to handle the field-format
PHEDEX.Util.sumArrayField=function(q,f,p) {
  var i, sum=0;
  if ( !p ) { p = parseInt; }
  for (i in q) {
    sum+= p(q[i][f]);
  }
  return sum;
}

PHEDEX.Util.toggleVisible = function(thisClass,el)
{
// find all elements with class=thisClass below el in the DOM. For those that have phedex-(in)visible set, toggle the value
  if (typeof(el) != 'object') {
    el = document.getElementById(el);
  }
  var i, e, elList = YuD.getElementsByClassName(thisClass,null,el)
  for (i in elList) {
    e = elList[i];
    if ( YuD.hasClass(e,'phedex-visible') ) {
      YuD.removeClass(e,'phedex-visible');
      YuD.addClass(e,'phedex-invisible');
    } else if ( YuD.hasClass(e,'phedex-invisible') ) {
      YuD.removeClass(e,'phedex-invisible');
      YuD.addClass(e,'phedex-visible');
    }
  }
}

PHEDEX.Util.initialCaps = function(str) {
  return str.substring(0,1).toUpperCase() + str.substring(1,str.length);
}

PHEDEX.Util.getConstructor = function( string ) {
  var x = string.split('-'),
      ctor = PHEDEX,
      c, j, field, k;
  for (j in x ) {
    if ( j == 0 && x[j] == 'phedex' ) { continue; }
    field = PxU.initialCaps(x[j]);
    if ( ctor[field] ) { c = ctor[field] }
    else {
      for (k in ctor) {
        field = k.toLowerCase();
        if ( field == x[j] ) {
          c = ctor[k];
          break;
        }
      }
    }
    if ( !c ) { return null; }
    ctor = c;
  }
  return ctor;
}

PHEDEX.Util.epochAlign = function(time,interval) {
/*
 * align a time to an interval. The time defaults to 'now', the interval defaults to one minute
 */
  if ( ! time ) {
    time = new Date();
    time = time.getTime() / 1000;
  }
  if ( !interval ) { interval = 60; }
  time = Math.round(time-time%interval);
  return time;
}

PHEDEX.Util.feature = {
  alpha: "<div class='feature-class feature-alpha' title='this feature is in alpha-release, expect bugs!'>&alpha;</div>",
  beta:  "<div class='feature-class feature-beta'  title='this feature is in beta-release, and may not be production quality'>&beta;</div>"
};
PHEDEX.Util.icon = {
  'red-circle':    "<img class='icon-class icon-red-circle'    title='red for danger, something is wrong here!'         src='"+PxW.BaseURL+"images/16-circle-red.png' />",
  'yellow-circle': "<img class='icon-class icon-yellow-circle' title='yellow for warning, something may be wrong here!' src='"+PxW.BaseURL+"images/16-circle-yellow.png' />",
  'green-circle':  "<img class='icon-class icon-green-circle'  title='green is good'                                    src='"+PxW.BaseURL+"images/16-circle-green.png' />",
};

/**
* This is the prototype for the string trim function. This is to trim the string 
* i.e to remove starting and trailing whitespace.
* @method trim
*/
String.prototype.trim = function() {
    return (this.replace(/^\s+|\s+$/g, ""));
}

/**
* This is the prototype for the string startswith function. This check if the string starts  
* with the given argument.
* @method startsWith
* @param {String} str is the string that has to be checked
*/
String.prototype.startsWith = function(str) {
    return (this.match("^" + str) == str);
}

var PxUf   = PxU.format;

log('loaded...','info','util');
