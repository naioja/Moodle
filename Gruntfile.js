var grunt = require('grunt');
require('load-grunt-tasks')(grunt);

var templates = ['nested/**/*.json', 'managedApplication/**/*.json', 'loadtest/*.json', 'migration/*.json', 'docs/*.json', 'etc/*.json', '*.json'];

grunt.initConfig({
  jshint: {
      files: templates,
      options: {
          jshintrc: '.jshintrc'
      }
  }
});
grunt.registerTask('test', ['jshint']);
