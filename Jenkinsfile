pipeline {
  agent any

  stages {
    stage('Build .NET') {
      steps {
        sh 'dotnet build'
      }
    }

    stage('Test') {
      steps {
        sh 'dotnet test'
      }
    }

    stage('Docker Build') {
      steps {
        sh 'docker build -t ghcr.io/tariqasifi/sportstore:latest .'
      }
    }
  }
}
#
