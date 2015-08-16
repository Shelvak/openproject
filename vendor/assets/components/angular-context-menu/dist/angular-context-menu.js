/**
 * @license
 * angular-context-menu - v0.1.2 - An AngularJS directive to display a context menu
 * (c) 2014
 * License: MIT
 *
 * @authors Brian Ford (http://briantford.com), Ian Kennington Walter (http://ianvonwalter.com), Till Breuer (https://github.com/tilt)
 */

angular.module('ng-context-menu', [])

.factory('ngContextMenu', [
  '$q',
  '$http',
  '$compile',
  '$templateCache',
  '$animate',
  '$rootScope',
  '$controller',
  function($q, $http, $compile, $templateCache, $animate, $rootScope, $controller) {

    return function contextMenuFactory(config) {
      if (!(!config.template ^ !config.templateUrl)) {
        throw new Error('Expected context menu to have exacly one of either `template` or `templateUrl`');
      }

      var template      = config.template,
          controller    = config.controller || angular.noop,
          controllerAs  = config.controllerAs,
          element       = null,
          container     = null,
          loadTemplate,
          target,
          scope;

      if (config.template) {
        var deferred = $q.defer();
        deferred.resolve(config.template);
        loadTemplate = deferred.promise;
      } else {
        loadTemplate = $http.get(config.templateUrl, {
          cache: $templateCache
        }).
        then(function (response) {
          return response.data;
        });
      }

      function open (target, locals, css) {
        this.target = target;

        if (scope && locals) {
          setLocals(locals);
        }

        return loadTemplate.then(function (html) {
          if (!element) {
            attach(html, locals);
          }
          if (css) {
            element.css(css);
          }

          return element;
        });
      }

      function attach (html, locals) {
        container = angular.element(config.container || document.body);
        element = angular.element(html);
        if (element.length === 0) {
         throw new Error('The template contains no elements; you need to wrap text nodes');
        }
        $animate.enter(element, container);

        // create a new scope and copy locals to it
        scope = $rootScope.$new();
        if (locals) {
          setLocals(locals);
        }

        var ctrl = $controller(controller, { $scope: scope });
        if (controllerAs) {
         scope[controllerAs] = ctrl;
        }
        $compile(element)(scope);
      }

      function setLocals (locals) {
        for (var prop in locals) {
         scope[prop] = locals[prop];
        }
      }

      function reposition (position) {
        if (element) {
          element.css(position);
        }
      }

      function close () {
        var deferred = $q.defer();
        if (element) {
          $animate.leave(element, function () {
            scope.$destroy();
            deferred.resolve();
          });

          if (this.target) {
            this.target.focus();
          }

          element = null;
        } else {
          deferred.resolve();
        }
        return deferred.promise;
      }

      function active () {
        return !!element;
      }

      return {
        open: open,
        close: close,
        active: active,
        reposition: reposition
      };

    };
}])

.directive('hasContextMenu', [
  '$injector',
  '$window',
  '$parse',
  '$timeout',
  '$animate',
  function($injector, $window, $parse, $timeout, $animate) {
  return {
    restrict: 'A',
    link: function(scope, element, attrs) {
      var contextMenu = $injector.get(attrs.target),
          locals = {},
          win = angular.element($window),
          menuElement,
          triggerOnEvent = attrs.triggerOnEvent || 'contextmenu',
          target,
          pointerOffset;

      /* contextMenu      is a mandatory attribute and used to bind a specific context
                          menu to the trigger event
         triggerOnEvent   allows for binding the event for opening the menu to "click" */

      // prepare locals, these define properties to be passed on to the context menu scope
      if (attrs.locals) {
        var localKeys = attrs.locals.split(',').map(function(local) {
          return local.trim();
        });
        angular.forEach(localKeys, function(key) {
          locals[key] = scope[key];
        });
      }

      function getPosition(target) {
        var targetPosition = {};
        var targetElement = angular.element(target);
        var bounding = targetElement[0].getBoundingClientRect();

        targetPosition.top = bounding.top;
        targetPosition.left = bounding.left;

        return targetPosition;
      }

      function getOffset(targetPosition, pointerPosition) {
        var pointerOffset = {};

        pointerOffset.offsetY = pointerPosition.top - targetPosition.top;
        pointerOffset.offsetX = pointerPosition.left - targetPosition.left;

        return pointerOffset;
      }

      function open(event) {
        var targetPosition = getPosition(event.target);
        var pointerPosition = getPositionPropertiesOfEvent(event);
        var contextMenuPromise = contextMenu.open(event.target, locals, getCssPositionPropertiesOfEvent(event));

        contextMenuPromise.then(function(element) {
          angular.element(element).trap();
          $animate.enter(element, document.body, element, function() {
            adjustPosition(element, pointerPosition);
          });
        });

        target = event.target;
        pointerOffset = getOffset(targetPosition, pointerPosition);
      }
      function adjustPosition($element, pointerPosition) {
        var win = angular.element($window);
        var viewport = {
          top : win.scrollTop(),
          left : win.scrollLeft()
        };
        
        viewport.right = viewport.left + win.width();
        viewport.bottom = viewport.top + win.height();
        var bounds = $element.offset();
        bounds.right = bounds.left + $element.outerWidth();
        bounds.bottom = bounds.top + $element.outerHeight();
        if (viewport.right < bounds.right) {
          $element.css("left", pointerPosition.left - $element.outerWidth());
        }
        if (viewport.bottom < bounds.bottom) {
          $element.css("top", pointerPosition.top - $element.outerHeight());
        }
      }

      function close() {
        contextMenu.close();
      }

      function getPositionPropertiesOfEvent(event) {
        var position = { };

        if (event.pageX && event.pageY) {
          position.top = Math.max(event.pageY, 0);
          position.left = Math.max(event.pageX, 0);
        } else {
          var bounding = angular.element(event.target)[0].getBoundingClientRect();

          position.top = Math.max(bounding.bottom, 0);
          position.left = Math.max(bounding.left, 0);
        }

        return position;
      }

      function getCssPositionPropertiesOfEvent(event) {
        var position = getPositionPropertiesOfEvent(event);

        position.top += 'px';
        position.left += 'px';

        return position;
      }

      function openContextMenu(event) {
        event.preventDefault();
        event.stopPropagation();

        scope.$apply(function() {
          open(event);
        });
      }

      function closeContextMenu() {
        scope.$apply(function() {
          close();
        });
      }

      element.bind(triggerOnEvent, function(event) {
        openContextMenu(event);
      });

      element.bind('keyup', function(event) {
        // Alt + Shift + F10
        if (event.keyCode === 121 && event.shiftKey && event.altKey) {
          if (!contextMenu.active()) {
            openContextMenu(event);
          }
        }
      });

      function handleWindowClickEvent(event) {
        if (contextMenu.active() && event.button !== 2) {
          closeContextMenu();
        }
      }

      // Firefox treats a right-click as a click and a contextmenu event while other browsers
      // just treat it as a contextmenu event
      win.bind('click', handleWindowClickEvent);
      win.bind(triggerOnEvent, handleWindowClickEvent);

      win.bind('keyup', function(event) {
        if (contextMenu.active() && event.keyCode === 27) {
          closeContextMenu();
        }
      });

      win.on('resize', function(event) {
        if (target) {
          var currentTargetPosition = getPosition(target);
          var position = {
            top: currentTargetPosition.top + pointerOffset.offsetY,
            left: currentTargetPosition.left + pointerOffset.offsetX
          };

          contextMenu.reposition(position);

          lastTargetPosition = currentTargetPosition;
        }
      });
    }
  };
}]);
