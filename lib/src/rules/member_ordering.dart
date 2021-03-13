import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:code_checker/checker.dart';
import 'package:code_checker/rules.dart';
import 'package:meta/meta.dart';

// Inspired by TSLint (https://palantir.github.io/tslint/rules/member-ordering/)

class MemberOrderingRule extends Rule {
  static const ruleId = 'member-ordering';
  static const _documentationUrl = 'https://git.io/JJwqN';

  static const _warningMessage = 'should be before';
  static const _warningAlphabeticalMessage = 'should be alphabetically before';

  final List<_MembersGroup> _groupsOrder;
  final bool _alphabetize;

  MemberOrderingRule({Map<String, Object> config = const {}})
      : _groupsOrder = _parseOrder(config),
        _alphabetize = (config['alphabetize'] as bool) ?? false,
        super(
          id: ruleId,
          documentation: Uri.parse(_documentationUrl),
          severity: readSeverity(config, Severity.style),
        );

  @override
  Iterable<Issue> check(ResolvedUnitResult source) {
    final _visitor = _Visitor(_groupsOrder);

    final membersInfo = [
      for (final entry in source.unit.childEntities)
        if (entry is ClassDeclaration) ...entry.accept(_visitor),
    ];

    return [
      ...membersInfo.where((info) => info.memberOrder.isWrong).map(
            (info) => createIssue(
              this,
              nodeLocation(
                node: info.classMember,
                source: source,
                withCommentOrMetadata: true,
              ),
              '${info.memberOrder.memberGroup.name} $_warningMessage ${info.memberOrder.previousMemberGroup.name}',
              null,
            ),
          ),
      if (_alphabetize)
        ...membersInfo
            .where((info) => info.memberOrder.isAlphabeticallyWrong)
            .map(
              (info) => createIssue(
                this,
                nodeLocation(
                  node: info.classMember,
                  source: source,
                  withCommentOrMetadata: true,
                ),
                '${info.memberOrder.memberNames.currentName} $_warningAlphabeticalMessage ${info.memberOrder.memberNames.previousName}',
                null,
              ),
            ),
    ];
  }

  static List<_MembersGroup> _parseOrder(Map<String, Object> config) {
    final order = config.containsKey('order') && config['order'] is Iterable
        ? List<String>.from(config['order'] as Iterable)
        : <String>[];

    return order.isEmpty
        ? _MembersGroup._groupsOrder
        : order
            .map(_MembersGroup.parse)
            .where((group) => group != null)
            .toList();
  }
}

class _Visitor extends RecursiveAstVisitor<List<_MemberInfo>> {
  final List<_MembersGroup> _groupsOrder;
  final _membersInfo = <_MemberInfo>[];

  _Visitor(this._groupsOrder);

  @override
  List<_MemberInfo> visitClassDeclaration(ClassDeclaration node) {
    super.visitClassDeclaration(node);

    _membersInfo.clear();

    for (final member in node.members) {
      if (member is FieldDeclaration) {
        _visitFieldDeclaration(member);
      } else if (member is ConstructorDeclaration) {
        _visitConstructorDeclaration(member);
      } else if (member is MethodDeclaration) {
        _visitMethodDeclaration(member);
      }
    }

    return _membersInfo;
  }

  void _visitFieldDeclaration(FieldDeclaration fieldDeclaration) {
    if (_hasMetadata(fieldDeclaration)) {
      return;
    }

    for (final variable in fieldDeclaration.fields.variables) {
      final membersGroup = Identifier.isPrivateName(variable.name.name)
          ? _MembersGroup.privateFields
          : _MembersGroup.publicFields;

      if (_groupsOrder.contains(membersGroup)) {
        _membersInfo.add(_MemberInfo(
          classMember: fieldDeclaration,
          memberOrder: _getOrder(membersGroup, variable.name.name),
        ));
      }
    }
  }

  void _visitConstructorDeclaration(
    ConstructorDeclaration constructorDeclaration,
  ) {
    if (_groupsOrder.contains(_MembersGroup.constructors)) {
      _membersInfo.add(_MemberInfo(
        classMember: constructorDeclaration,
        memberOrder: _getOrder(
          _MembersGroup.constructors,
          constructorDeclaration.name?.name ?? '',
        ),
      ));
    }
  }

  void _visitMethodDeclaration(MethodDeclaration methodDeclaration) {
    if (_hasMetadata(methodDeclaration)) {
      return;
    }

    _MembersGroup membersGroup;

    if (methodDeclaration.isGetter) {
      membersGroup = Identifier.isPrivateName(methodDeclaration.name.name)
          ? _MembersGroup.privateGetters
          : _MembersGroup.publicGetters;
    } else if (methodDeclaration.isSetter) {
      membersGroup = Identifier.isPrivateName(methodDeclaration.name.name)
          ? _MembersGroup.privateSetters
          : _MembersGroup.publicSetters;
    } else {
      membersGroup = Identifier.isPrivateName(methodDeclaration.name.name)
          ? _MembersGroup.privateMethods
          : _MembersGroup.publicMethods;
    }

    if (_groupsOrder.contains(membersGroup)) {
      _membersInfo.add(_MemberInfo(
        classMember: methodDeclaration,
        memberOrder: _getOrder(membersGroup, methodDeclaration.name.name),
      ));
    }
  }

  bool _hasMetadata(ClassMember classMember) {
    for (final data in classMember.metadata) {
      final annotation = _Annotation.parse(data.name.name);
      final memberName = classMember is FieldDeclaration
          ? classMember.fields.variables.first.name.name
          : classMember is MethodDeclaration
              ? classMember.name.name
              : '';

      if (annotation != null && _groupsOrder.contains(annotation.group)) {
        _membersInfo.add(_MemberInfo(
          classMember: classMember,
          memberOrder: _getOrder(annotation.group, memberName),
        ));

        return true;
      }
    }

    return false;
  }

  _MemberOrder _getOrder(_MembersGroup memberGroup, String memberName) {
    if (_membersInfo.isNotEmpty) {
      final lastMemberOrder = _membersInfo.last.memberOrder;
      final hasSameGroup = lastMemberOrder.memberGroup == memberGroup;

      final previousMemberGroup = hasSameGroup
          ? lastMemberOrder.previousMemberGroup
          : lastMemberOrder.memberGroup;

      final memberNames = _MemberNames(
        currentName: memberName,
        previousName: lastMemberOrder.memberNames.currentName,
      );

      return _MemberOrder(
        memberNames: memberNames,
        isAlphabeticallyWrong: hasSameGroup &&
            memberNames.currentName.compareTo(memberNames.previousName) != 1,
        memberGroup: memberGroup,
        previousMemberGroup: previousMemberGroup,
        isWrong: (hasSameGroup && lastMemberOrder.isWrong) ||
            _isCurrentGroupBefore(lastMemberOrder.memberGroup, memberGroup),
      );
    }

    return _MemberOrder(
      memberNames: _MemberNames(currentName: memberName),
      isAlphabeticallyWrong: false,
      memberGroup: memberGroup,
      isWrong: false,
    );
  }

  bool _isCurrentGroupBefore(
    _MembersGroup lastMemberGroup,
    _MembersGroup memberGroup,
  ) =>
      _groupsOrder.indexOf(lastMemberGroup) > _groupsOrder.indexOf(memberGroup);
}

@immutable
class _MembersGroup {
  final String name;

  // Generic
  static const publicFields = _MembersGroup._('public_fields');
  static const privateFields = _MembersGroup._('private_fields');
  static const publicGetters = _MembersGroup._('public_getters');
  static const privateGetters = _MembersGroup._('private_getters');
  static const publicSetters = _MembersGroup._('public_setters');
  static const privateSetters = _MembersGroup._('private_setters');
  static const publicMethods = _MembersGroup._('public_methods');
  static const privateMethods = _MembersGroup._('private_methods');
  static const constructors = _MembersGroup._('constructors');

  // Angular
  static const angularInputs = _MembersGroup._('angular_inputs');
  static const angularOutputs = _MembersGroup._('angular_outputs');
  static const angularHostBindings = _MembersGroup._('angular_host_bindings');
  static const angularHostListeners = _MembersGroup._('angular_host_listeners');
  static const angularViewChildren = _MembersGroup._('angular_view_children');
  static const angularContentChildren =
      _MembersGroup._('angular_content_children');

  static const _groupsOrder = [
    publicFields,
    privateFields,
    publicGetters,
    privateGetters,
    publicSetters,
    privateSetters,
    constructors,
    publicMethods,
    privateMethods,
    angularInputs,
    angularOutputs,
    angularHostBindings,
    angularHostListeners,
    angularViewChildren,
    angularContentChildren,
  ];

  const _MembersGroup._(this.name);

  static _MembersGroup parse(String name) => _groupsOrder
      .firstWhere((group) => group.name == name, orElse: () => null);
}

@immutable
class _Annotation {
  final String name;
  final _MembersGroup group;

  static const input = _Annotation._('Input', _MembersGroup.angularInputs);
  static const output = _Annotation._('Output', _MembersGroup.angularOutputs);
  static const hostBinding =
      _Annotation._('HostBinding', _MembersGroup.angularHostBindings);
  static const hostListener =
      _Annotation._('HostListener', _MembersGroup.angularHostListeners);
  static const viewChild =
      _Annotation._('ViewChild', _MembersGroup.angularViewChildren);
  static const viewChildren =
      _Annotation._('ViewChildren', _MembersGroup.angularViewChildren);
  static const contentChild =
      _Annotation._('ContentChild', _MembersGroup.angularContentChildren);
  static const contentChildren =
      _Annotation._('ContentChildren', _MembersGroup.angularContentChildren);

  static const _annotations = [
    input,
    output,
    hostBinding,
    hostListener,
    viewChild,
    viewChildren,
    contentChild,
    contentChildren,
  ];

  const _Annotation._(this.name, this.group);

  static _Annotation parse(String name) => _annotations
      .firstWhere((annotation) => annotation.name == name, orElse: () => null);
}

@immutable
class _MemberInfo {
  final ClassMember classMember;
  final _MemberOrder memberOrder;

  const _MemberInfo({
    this.classMember,
    this.memberOrder,
  });
}

@immutable
class _MemberOrder {
  final bool isWrong;
  final bool isAlphabeticallyWrong;
  final _MemberNames memberNames;
  final _MembersGroup memberGroup;
  final _MembersGroup previousMemberGroup;

  const _MemberOrder({
    this.isWrong,
    this.isAlphabeticallyWrong,
    this.memberNames,
    this.memberGroup,
    this.previousMemberGroup,
  });
}

@immutable
class _MemberNames {
  final String currentName;
  final String previousName;

  const _MemberNames({
    this.currentName,
    this.previousName,
  });
}
