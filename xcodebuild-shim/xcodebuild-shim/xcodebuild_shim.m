//
// Copyright 2013 Facebook
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import <objc/message.h>
#import <objc/runtime.h>

#import <Foundation/Foundation.h>

#import "ReporterEvents.h"

static int __stdoutHandle;
static FILE *__stdout;
static int __stderrHandle;
static FILE *__stderr;

static NSMutableSet *__begunLogSections = nil;
static NSMutableSet *__endedLogSections = nil;

static void XTSwizzleSelectorForFunction(Class cls, SEL sel, IMP newImp)
{
  Method originalMethod = class_getInstanceMethod(cls, sel);
  const char *typeEncoding = method_getTypeEncoding(originalMethod);

  NSString *newSelectorName = [NSString stringWithFormat:@"__%s_%s", class_getName(cls), sel_getName(sel)];
  SEL newSelector = sel_registerName([newSelectorName UTF8String]);
  class_addMethod(cls, newSelector, newImp, typeEncoding);

  Method newMethod = class_getInstanceMethod(cls, newSelector);
  method_exchangeImplementations(originalMethod, newMethod);
}

@interface IDEActivityLogSection : NSObject

// Will be 0 for success, 1 for failure.
@property (readonly) long long resultCode;

// Indicates the type of message.  This will be 'com.apple.dt.IDE.BuildLogSection' in the case of
// individual build commands (like compile, link, run script, etc.), and it will be
// 'Xcode.IDEActivityLogDomainType.target.product-type.application' in the case of the blah
@property (readonly) id domainType;

// Text of the command about to be run.  e.g., CompileC ...
@property (readonly) NSString *commandDetailDescription;

// Output text of command; nil if command succeeds.
@property (readonly) NSString *emittedOutputText;

// A short description about what's being run, e.g. 'CompileC path/to/Some.m'
@property (readonly) NSString *title;

// Array of IDEDiagnosticActivityLogMessage.  We won't do anything with these for now, but they're
// really interesting.  If there's a build error, these objects will tell you the file and column
// location of the error, severity, and the list of fix-it tips Xcode would normally show.
@property (readonly) NSArray *messages;

@property(readonly) double timeStoppedRecording;
@property(readonly) double timeStartedRecording;

@end

#define kDomainTypeBuildItem @"com.apple.dt.IDE.BuildLogSection"
#define kDomainTypeProductItemPrefix @"Xcode.IDEActivityLogDomainType.target.product-type"

static void GetProjectTargetConfigurationFromHeader(NSString *header,
                                                    NSString **project,
                                                    NSString **target,
                                                    NSString **configuration)
{
  // Pull out the pieces from the header that looks like --
  // === BUILD NATIVE TARGET TestTest OF PROJECT TestTest WITH THE DEFAULT CONFIGURATION (Release) ===

  NSScanner *scanner = [NSScanner scannerWithString:header];
  [scanner setCharactersToBeSkipped:nil];

  if (![scanner scanUpToString:@"TARGET " intoString:nil]) {
    goto Error;
  }

  [scanner scanString:@"TARGET " intoString:nil];

  if (![scanner scanUpToString:@" OF PROJECT " intoString:target]) {
    goto Error;
  }

  [scanner scanString:@" OF PROJECT " intoString:nil];

  if (![scanner scanUpToString:@" WITH " intoString:project]) {
    goto Error;
  }

  if (![scanner scanUpToString:@" CONFIGURATION " intoString:nil]) {
    goto Error;
  }

  [scanner scanString:@" CONFIGURATION " intoString:nil];

  if (![scanner scanUpToString:@" ===" intoString:configuration]) {
    goto Error;
  }

  return;
Error:
  fprintf(__stderr,
          "ERROR: Error parsing project, target, configuration from header '%s'.\n",
          [header UTF8String]);
  exit(1);
}

static void PrintJSON(id JSONObject)
{
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:JSONObject options:0 error:&error];

  if (error) {
    fprintf(__stderr,
            "ERROR: Error generating JSON for object: %s: %s\n",
            [[JSONObject description] UTF8String],
            [[error localizedFailureReason] UTF8String]);
    exit(1);
  }

  fwrite([data bytes], 1, [data length], __stdout);
  fputs("\n", __stdout);
  fflush(__stdout);
}

static void AnnounceBeginSection(IDEActivityLogSection *section)
{
  NSString *sectionTypeString = [section.domainType description];

  if ([sectionTypeString isEqualToString:kDomainTypeBuildItem]) {
    PrintJSON(@{
              @"event" : kReporter_Events_BeginBuildCommand,
              kReporter_BeginBuildCommand_TitleKey : section.title,
              kReporter_BeginBuildCommand_CommandKey : section.commandDetailDescription,
              });
  } else if ([sectionTypeString hasPrefix:kDomainTypeProductItemPrefix]) {
    NSString *project = nil;
    NSString *target = nil;
    NSString *configuration = nil;
    GetProjectTargetConfigurationFromHeader(section.title, &project, &target, &configuration);
    PrintJSON(@{
              @"event" : kReporter_Events_BeginBuildTarget,
              kReporter_BeginBuildTarget_ProjectKey : project,
              kReporter_BeginBuildTarget_TargetKey : target,
              kReporter_BeginBuildTarget_ConfigurationKey : configuration,
              });
  }
}

static void AnnounceEndSection(IDEActivityLogSection *section)
{
  NSString *sectionTypeString = [section.domainType description];

  if ([sectionTypeString isEqualToString:kDomainTypeBuildItem]) {
    PrintJSON(@{
              @"event" : kReporter_Events_EndBuildCommand,
              kReporter_EndBuildCommand_TitleKey : section.title,
              kReporter_EndBuildCommand_SucceededKey : (section.resultCode == 0) ? @YES : @NO,
              // Sometimes things will fail and 'emittedOutputText' will be nil.  We've seen this
              // happen when Xcode's Copy command fails.  In this case, just send an empty string
              // so Reporters don't have to worry about this sometimes being [NSNull null].
              kReporter_EndBuildCommand_EmittedOutputTextKey : section.emittedOutputText ?: @"",
              kReporter_EndBuildCommand_DurationKey : @(section.timeStoppedRecording - section.timeStartedRecording),
              });
  } else if ([sectionTypeString hasPrefix:kDomainTypeProductItemPrefix]) {
    NSString *project = nil;
    NSString *target = nil;
    NSString *configuration = nil;
    GetProjectTargetConfigurationFromHeader(section.title, &project, &target, &configuration);
    PrintJSON(@{
              @"event" : kReporter_Events_EndBuildTarget,
              kReporter_EndBuildTarget_ProjectKey : project,
              kReporter_EndBuildTarget_TargetKey : target,
              kReporter_EndBuildTarget_ConfigurationKey : configuration,
              });
  }
}

static void HandleBeginSection(IDEActivityLogSection *section)
{
  [__begunLogSections addObject:section];

  if ([__endedLogSections containsObject:section]) {
    // We've gotten the end message before the begin message.
    AnnounceBeginSection(section);
    AnnounceEndSection(section);
  } else {
    AnnounceBeginSection(section);
  }
}

static void HandleEndSection(IDEActivityLogSection *section)
{
  [__endedLogSections addObject:section];

  if ([__begunLogSections containsObject:section]) {
    AnnounceEndSection(section);
  }
}

static void Xcode3CommandLineBuildLogRecorder__emitSection(id self, SEL cmd, IDEActivityLogSection *section)
{
  // Call through to the original implementation.
  objc_msgSend(self, sel_getUid("__Xcode3CommandLineBuildLogRecorder__emitSection:"), section);

  HandleBeginSection(section);
}

static void Xcode3CommandLineBuildLogRecorder__finishEmittingClosedSection(id self, SEL sel, IDEActivityLogSection *section)
{
  // Call through to the original implementation.
  objc_msgSend(self, sel_getUid("__Xcode3CommandLineBuildLogRecorder__finishEmittingClosedSection:"), section);

  HandleEndSection(section);
}

static void IDECommandLineBuildLogRecorder__emitSection_inSupersection(id self,
                                                                       SEL sel,
                                                                       IDEActivityLogSection *section,
                                                                       id supersection)
{
  // Call through to the original implementation.
  objc_msgSend(self, sel_getUid("__IDECommandLineBuildLogRecorder__emitSection:inSupersection:"), section, supersection);

  HandleBeginSection(section);
}

static void IDECommandLineBuildLogRecorder__cleanupClosedSection_inSupersection(id self,
                                                                                SEL sel,
                                                                                IDEActivityLogSection *section,
                                                                                id supersection)
{
  // Call through to the original implementation.
  objc_msgSend(self, sel_getUid("__IDECommandLineBuildLogRecorder__cleanupClosedSection:inSupersection:"), section, supersection);

  HandleEndSection(section);
}

/**
 xcodebuild will call printErrorString:andFailWithCode: whenever it exits with
 an error, and we'll turn that into a JSON event.  We won't let this event float
 up to the reporters they - we'll capture it in 
 LaunchXcodebuildTaskAndFeedEventsToReporters()
 */
static void Xcode3CommandLineBuildTool__printErrorString_andFailWithCode(id self, SEL sel, NSString *str, long long code)
{
  PrintJSON(@{
            @"event" : @"__xcodebuild-error__",
            @"message" : str,
            @"code" : @(code),
            });
 objc_msgSend(self,
               @selector(__Xcode3CommandLineBuildTool__printErrorString:andFailWithCode:),
               str,
               code);
}

__attribute__((constructor)) static void EntryPoint()
{
  __stdoutHandle = dup(STDOUT_FILENO);
  __stdout = fdopen(__stdoutHandle, "w");
  __stderrHandle = dup(STDERR_FILENO);
  __stderr = fdopen(__stderrHandle, "w");

  // Prevent xcodebuild from outputing anything over stdout / stderr as it normally would.
  freopen("/dev/null", "w", stdout);
  freopen("/dev/null", "w", stderr);

  __begunLogSections = [[NSMutableSet alloc] initWithCapacity:0];
  __endedLogSections = [[NSMutableSet alloc] initWithCapacity:0];

  BOOL isXcode5 = (NSClassFromString(@"IDECommandLineBuildLogRecorder") != NULL);
  BOOL isXcode4 = (NSClassFromString(@"Xcode3CommandLineBuildLogRecorder") != NULL);

  // For each log item, Xcode will call a begin and end method.  (The naming of
  // these methods is slightly different betwen Xcode 4 and 5.)
  //
  // This begin method is meant to announce the action that will be done. e.g.,
  // this would get called to print out the clang command that's about to be
  // executed.
  //
  // The end method is called once for every line item in the log, and is meant
  // to announce the result of something.  e.g., this would print out the error
  // text (if any) from a clang command that just ran.
  if (isXcode5) {
    XTSwizzleSelectorForFunction(NSClassFromString(@"IDECommandLineBuildLogRecorder"),
                                 @selector(_emitSection:inSupersection:),
                                 (IMP)IDECommandLineBuildLogRecorder__emitSection_inSupersection);
    XTSwizzleSelectorForFunction(NSClassFromString(@"IDECommandLineBuildLogRecorder"),
                                 @selector(_cleanupClosedSection:inSupersection:),
                                 (IMP)IDECommandLineBuildLogRecorder__cleanupClosedSection_inSupersection);
  } else if (isXcode4) {
    XTSwizzleSelectorForFunction(NSClassFromString(@"Xcode3CommandLineBuildLogRecorder"),
                                 @selector(_emitSection:),
                                 (IMP)Xcode3CommandLineBuildLogRecorder__emitSection);
    XTSwizzleSelectorForFunction(NSClassFromString(@"Xcode3CommandLineBuildLogRecorder"),
                                 @selector(_finishEmittingClosedSection:),
                                 (IMP)Xcode3CommandLineBuildLogRecorder__finishEmittingClosedSection);
  } else {
    NSCAssert(NO,
              @"Hrm. We're running in a version of xcodebuild which seems "
              @"to be from neither Xcode4 or Xcode5.");
  }

  // When xcodebuild is going to fail, it prints out the error via this method.
  // Let's capture it and write the output in a structured form.
  XTSwizzleSelectorForFunction(NSClassFromString(@"Xcode3CommandLineBuildTool"),
                               @selector(_printErrorString:andFailWithCode:),
                               (IMP)Xcode3CommandLineBuildTool__printErrorString_andFailWithCode);

  // Unset so we don't cascade into other process that get spawned from xcodebuild.
  unsetenv("DYLD_INSERT_LIBRARIES");
}
