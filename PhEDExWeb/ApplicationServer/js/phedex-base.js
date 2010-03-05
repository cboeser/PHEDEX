/**
 * The PhEDEx Application.
 * @module PHEDEX
 * @title Documentation for the PhEDEx website packages
 */
var YuE = YAHOO.util.Event, // for convenience...
    YuD = YAHOO.util.Dom,
    Yla = YAHOO.lang.augmentObject;

/**
 * The PHEDEX global namespace object.
 * @namespace
 * @class PHEDEX
 * @static
 */
PHEDEX= {}

/**
 * Creates a namespace rooted from PHEDEX.
 * <pre>
 * PHEDEX.namespace('Core','Component');
 * </pre>
 * @method namespace
 * @static
 * @param namespace {string*} Namespace(s) to create, optionally with  dot-notation, e.g. 'Appserv' or 'Base.Object'.
 * @return {object} The namespace created.
 */
// For more information, see: http://yuiblog.com/blog/2007/06/12/module-pattern/
PHEDEX.namespace = function() {
    var a=arguments, o=null, i, j, d, k;
    i=a.length;
    while ( i > 0 ) {
        i--;
        d=(""+a[i]).split(".");
        o=PHEDEX;

        // PHEDEX is implied, so it is ignored if it is included
        k=d.length;
        j=(d[0] == "PHEDEX") ? 1 : 0;
        while ( j<k ) {
            o[d[j]]=o[d[j]] || {};
            o=o[d[j]];
            j=j+1;
        }
    }
    return o;
};

/**
 * Contains application globals.
 * @namespace PHEDEX
 * @class Appserv
 */
PHEDEX.namespace('Appserv');

/**
 * Sets the version of the application, using a string set by the RPM build or a default.
 * @method makeVersion
 * @namespace PHEDEX.Appserv
 * @protected
 * @return {string} The version string
 */
PHEDEX.Appserv.makeVersion = function() {
  var version = '@APPSERV_VERSION@'; // set when RPM is built
  return version.match(/APPSERV_VERSION/) ? '0.0.0' : version;
};

/**
 * The version of the application.
 * @property Version
 * @type string
 * @public
 */
PHEDEX.Appserv.Version = PHEDEX.Appserv.makeVersion();

/**
 * Contains utility functions.
 * @namespace PHEDEX
 * @class Util
 */
PHEDEX.Util = {
/** format an exception object into a sensible error-message
 * @namespace PHEDEX.Util
 * @method err
 * @param ex {object} An exception-object, assumed to have <strong>name</strong>, <strong>message</strong>, <strong>fileName</strong> and <strong>lineNumber</strong> members.
 */
  err: function(ex) { return ex.name+': '+ex.message+' ('+ex.fileName+':'+ex.lineNumber+')'; },

/** a simple logging function, to get it all working. This is overridden by PHEDEX.Logger, later. This function will write messages int an element with Id=<strong>phedex-logger-inner</strong> if such an element exists. This function also buffers, ad infinitem, the messages it receives. This allows a future call to this function to retrieve those messages for re-sending to a proper logging facility.
 * @namespace PHEDEX.Base
 * @method log
 * @param str {string} text of error message. Leave blank to return an array of all messages recorded so far.
 * @param level {string} severity-level (optional), use the same classes as for the YAHOO logger.
 * @param group {string} message-group (optional), the group to which this message belongs
 */
  log: function() {
    var _buffer = [],
        el = document.getElementById('phedex-logger-inner');
    return function(str,level,group) {
      if ( str ) {
        if ( typeof(str) == 'object' ) {
          try { str = err(str); } // assume it's an exception object!
          catch (ex) { } // ignore the error if it wasn't an exception object...
        }
        if ( el ) {
          el.innerHTML += str+'<br/>';
          if (typeof el.scrollTop != 'undefined') { el.scrollTop += 100; }
        }
      _buffer.push([str,level,group]);
      if ( _buffer.length > 100 ) { delete _buffer[0]; }
      } else {
        var b = _buffer; // gymnastics to reset _buffer to empty within a closure, but still return its contents!
        _buffer = [];
        return b;
      }
    };
  }(),

/** put messages on a banner, useful to give the user the illusion of progress. Requires that the DOM contain an element with Id=<strong>phedex-banner-messages-outer</strong>, and inside that an element with Id=<strong>phedex-banner-messages-inner</strong>. The outer element will have its visibility turned on/off as needed, the inner element will be styled to colour-code messages for severity. Messages of higher severity will persist longer than messages of lower severity, so they can be more easily seen.
 * @method banner
 * @param str {string} the message string
 * @param level {string} severity-level. Known severities are <strong>info</strong>, <strong>warn</strong>, <strong>error</strong> and <strong>default</strong>.
 * @param group {string} message-group. Not used at the moment, but provides symmetry with the logger, in case these functions should be coupled someday.
 */
  banner: function() {
    var outer = document.getElementById('phedex-banner-messages-outer'),
        inner = document.getElementById('phedex-banner-messages-inner'),
        classNames = {
          info:   'phedex-bkg-green',
          warn:   'phedex-bkg-yellow',
          error:  'phedex-bkg-red',
          def:'phedex-bkg-turquoise'
        },
        order = { def:0, info:1, warn:2, error:3 },
        current;
    if ( !outer ) { return; }
    var fade = function() {
      current--;
      if ( current < 2 ) { return; }
      setTimeout( function() { fade(); }, 2500 );
    }
    return function(str,level,group) {
      if ( outer ) {
        if ( str ) {
          if ( !level ) { level = 'def'; }
          if ( order[level] < current ) { return; }
          inner.innerHTML = str;
          current = order[level];
          inner.className = classNames[level] + ' phedex-messages-inner';
          YAHOO.util.Dom.removeClass(outer,'phedex-invisible');
          fade();
        } else {
          YAHOO.util.Dom.addClass(outer,'phedex-invisible');
        }
      }
    };
  }(),

/** Use the IdleTimer from Zackas to drive the banner, prompting the user for input if they do nothing for a while.
 * @method bannerIdleTimer
 * @param Loader {PHEDEX.Loader} A PHEDEX.Loader instance
 */
  bannerIdleTimer: function(Loader) {
    Loader.load(function() {
      var IdleTimer = new PHEDEX.Util.IdleTimer();
      IdleTimer.subscribe('idle',   function() { banner('waiting for your input'); });
      IdleTimer.subscribe('active', function() { banner(); });
      IdleTimer.start(10000);
    },'util-idletimer');
  }
};

PHEDEX.Base = {
/** Base object for all graphical entities in the application. Should not be instantiated on its own. It has no methods, only structural components, so that derived objects do not have to test for the existance of such components before accessing elements of them.
 * @namespace PHEDEX.Base
 * @class Object
 * @constructor
 */
  Object: function() {
    return {
      /**
       * Namespace for DOM elements managed by this object.
       * @property dom
       * @type object
       * @protected
       */
      dom: {},

      /**
       * Namespace for control elements managed by this object.
       * @property ctl
       * @type object
       * @protected
       */
      ctl: {},

      /**
       * Namespace for options in effect for this object.
       * @property options
       * @type object
       * @protected
       */
      options: {},

      /**
       * Decorations to apply for this object. E.g, context-menus, 'extra' handlers etc
       * @property decorators
       * @type array
       * @protected
       */
      decorators: []
    };
  }
}

var log    = PHEDEX.Util.log,
    err    = PHEDEX.Util.err,
    banner = PHEDEX.Util.banner;