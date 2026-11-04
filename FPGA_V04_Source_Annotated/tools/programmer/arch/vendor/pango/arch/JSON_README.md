# **此文件是针对当前文件夹下的json文件的配置说明**

不包含SimOption*.json（但是功能是类似的）



## Option.json

配置不同action下，分别有什么选项，以及选项的基本属性。

以gen_netlist为例子：

```
	"gen_netlist":[
		["input_db_file", "Specify the input design DB file name", "OptString", "Dev"],
	    ["force_to_run", "Run this action without checking the status", "OptSwitch", "Dev"],
	
	    ["func_sim_only", "Generate netlist for functional simulation only", "OptSwitch", "All"],
	    ["sdf_annotate", "Enable Sdf Annotate", "OptBool", "All", "Specify if enable the sdf_annotate system task."],
	    ["process_corner", "Process Corner", "OptString", "All", "Specify process corner for SDF delays(slow or fast)."]
	],
```

内层数组中，每列的含义分别为：

tcl名，对用户的显示名，选项的值的类型，编译选项，功能说明（可选）。



相关解释说明：

1）tcl名：程序中对应的tcl选项名，在action内必须唯一，是区分不同选项的唯一依据；

2）对用户的显示名：Project Settings界面中，具体某一选项用于展示的字符串；

3）选项的值的类型：对应代码中的tciOptSwitch、tciOptInt等相关class，目前支持配置的类型有：

        OptSwitch,
        OptBool,
        OptInt,
        OptSyn,
        OptDouble,
        OptString,
        OptListString,
        OptListListString

4）编译选项：为了兼容原有代码，在启用特定宏的时候才创建option，目前有："Ads"、"Dev"、"All"三种，分别对应\_ENABLE_ADS使能启用、\_COMPILE_DEV使能启用、其他情况下使能启用；

5）功能说明：在Project Setting界面中，点击某一选项，在下方展示的提示信息 。

​	



## OptionClass.json

action的每个option在Project Setting界面上显示在哪个Tab标签上（如果这个选项需要被显示的话）;
选项在此文件中的顺序决定了Project Setting中显示的顺序。





## OptionValue.json

定义了不同器件、不同综合工具下有什么option，以及option的默认值，和一些值的额外信息。

文件整体结构如下：

```
{
	"ads()":{```````````},
	"synplify_pro()":{```````````},

	"Common()":{```````````},
	
	"Titan()":{```````````},
	"Logos()":{```````````},
	
	"PGT30G()":{```````````},
	"PGT180H()":{```````````},
	"PGL12G()":{```````````},
	"PGL22G()":{```````````},

	"PGL22G-FBG256()":{```````````},
}
```

其中关键字的结构是device(display)
device是器件的内部研发名，display是器件的外部显示名
()括号不可缺省，
如果该device对应所有display的配置全部相同，则括号里面的内容可以缺省
如果该device对应所有display的配置不完全相同， 则需要进行分组，相同配置的display为一组 ，所有display需要全部列出来， 比如：
"device(display1,display2,display5)":{},
"device(display3,display4)":{}


从低层结构看，里面配置了每个选项的默认值和候选值列表等信息，以gen_netlist为例子：

```
        "gen_netlist":[
            ["input_db_file",                       null,           {"ShellOnly": null} ],
            ["force_to_run",                        null,           {"ShellOnly": null} ],
            
            ["func_sim_only",                       null,           {"ShellOnly": null} ],
            ["process_corner",                      "slow",         {"Candidate": ["slow", "fast"]} ],
            ["sdf_annotate",                        null,           {} ]
        ],
```

内层数组中，每列的含义分别为：
tcl名，默认值，额外的（特殊的）配置信息。

额外的（特殊的）配置信息这个json object，目前支持以下这些配置（Key， Value对）：

```
"Candidate",                  //表示输入值有个候选值列表，Value形如：["slow", "fast"]
"Range",                      //表示输入值有范围限制，Value形如：[2000, 1000000]
"Step",						  //表示输入值在界面上点击箭头修改值的步长，Value为一个数字，此项必须配合"Range"使用

"ShellOnly",                  //表示此选项不在UI上显示，供shell使用，Value值为bool类型
"Hidden",                     //表示此选项不在UI上显示，同时，在tcl中输入help时，此选项不显示出来，Value值为bool类型
"Locked",                     //表示锁定，值不可修改，Value值为bool类型
"InputFile",                  //表示此选项的值是个已存在的文件路径（输入检查用），Value值必须为null
"Dir",              		  //表示此选项的值是个已存在的目录路径（输入检查用），Value值必须为null
"Positive",                   //表示此选项的值大于0，Value值必须为null
```



- [ ] 注：目前，切换器件时不会去清空当前设置，但会以Common、family、device、device-package、device-package-speedgrade的顺序重新设置一次配置信息。






## SynToolValidOptClass.json

配置的是选择不同综合工具的时候，在界面上显示哪些标签



## OptionStrategy.json
该文件用来配置内置策略

Strategy :该字段下，以阶段作为区分，编写各个阶段所有策略配置
默认策略为空策略，不建议更改内容和顺序

对于策略包含以下字段：
inner_name:策略内置名字，具有唯一性，所有策略内置名应该唯一，做内置区分
display_name:策略对外显示名，用户可见额策略名字
上述设计，是为了解决，不同器件策略含义一致，则显示名一致，但配置不同，因此以内置名进行配置区分

description：描述信息，策略说明
options：该阶段，该策略的选项配置
testparams：该策略的参数配置

器件配置
不同器件，不同阶段可选策略不同

	"Common()":{```````````},
	
	"Titan()":{```````````},
	"Logos()":{```````````},
	
	"PGT30G()":{```````````},
	"PGT180H()":{```````````},
	"PGL12G()":{```````````},
	"PGL22G()":{```````````},

	"PGL22G-FBG256()":{```````````},

其中关键字的结构是device(display)
device是器件的内部研发名，display是器件的外部显示名
()括号不可缺省，
如果该device对应所有display的配置全部相同，则括号里面的内容可以缺省
如果该device对应所有display的配置不完全相同， 则需要进行分组，相同配置的display为一组 ，所有display需要全部列出来， 比如：
"device(display1,display2,display5)":{},
"device(display3,display4)":{}

以阶段的方式，列出该器件可选策略，使用内置列出

默认配置写在首位，不可更改



# 界面上的选项关联更新以及选项检查

## 选项的界面关联更新

典型场景是，在Project Settings界面的某一个选项勾选后，另一个选项a需要灰选，另一个选项b取消勾选，另一个选项c值改为XXX。

目前，这类处理集中到了class RelatedOptUpdater和其子类class GUIRelatedOptUpdater， 界面上相应选项的值发生变化后会执行相关函数以更新UI。
其中，父类实现tcl的关联值更新的函数，子类实现project setting关联值更新的函数；在父类构造函数列出关联值更新列表

以回调函数GUIOnPersistIpalChanged和TCLOnPersistIpalChanged为例，
在界面配置persist_ipal选项的值后，会调用GUIOnPersistIpalChanged，在函数体中更新选项persist_slave_parallel_pins的值；
使用命令配置persist_ipal和persist_slave_parallel_pins选项的值后，会调用TCLOnPersistIpalChanged或者TCLOnPersistChanged，在函数体中更新选项persist_slave_parallel_pins或者persist_ipal的值，不合法的配置就会被舍弃

类似的，如果需要新增一个检测，参考回调函数GUIOnPersistIpalChanged，我们只需要写一个新的回调函数OptionCallBack,并把OptionCallBack到函数InitCallback注册就好了。

此外，还需注意一点，GUIOnPersistIpalChanged(wgtConfigureTciOptPanel * p)的入参p，是指选项所在的Tab标签页。以PnR为例，目前有General，Placement，Router三个标签页，用p->GetOptEditor的方法只能获取到本标签页下的选项的值，如果需要获取同一个action下别的标签页下选项的值，参见函数FindTciOptPanel。



## 选项检查

这类问题集中在class OptionValueChecker处理，Project Settings界面和Tcl命令入口都会触发相关检查。
新增一个检查的步骤和问题一种的类似，新增一个callback，注册这个callback，没什么特别的。

注：和问题1中的wgtConfigureTciOptPanel不同的是，IContext可以获取当前action所有的选项的值（器件若不支持，返回值未定义）

